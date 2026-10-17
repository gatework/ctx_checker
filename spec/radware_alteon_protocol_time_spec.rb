# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/radware_alteon/parsers/info_sys_general"
require "ctx_checker/radware_alteon/parsers/stats_sys_ntp"
require "ctx_checker/radware_alteon/parsers/info_l3_bgp_summary"
require "ctx_checker/radware_alteon/parsers/info_l3_ospf_nbr"

RSpec.describe "Alteon protocol and time evidence" do
  # 脱敏样本保留已观察命令语法，不包含设备标识。
  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/#{name}.txt", __dir__))
  end

  # 时钟投影独立于通用信息中的其他元数据。
  def clock(text = fixture(:general), complete: true)
    CtxChecker::RadwareAlteon::Parsers::InfoSysGeneral.parse(text, complete: complete)
  end

  # 同一命令分别产生 NTP 与设备计数器观测。
  def ntp(text = fixture(:ntp), complete: true)
    CtxChecker::RadwareAlteon::Parsers::StatsSysNtp.parse(text, complete: complete).by_dimension
  end

  # 厂商协议语法不继承无关的 Cisco 回显布局。
  def protocol(name, text, complete: true)
    klass = name == :bgp ? CtxChecker::RadwareAlteon::Parsers::InfoL3BgpSummary : CtxChecker::RadwareAlteon::Parsers::InfoL3OspfNbr
    klass.parse(text, complete: complete)
  end

  it "uses the explicit GMT offset even when the named timezone is not configured" do
    result = clock
    expect(result).to be_complete
    expect(result.records).to eq([ { component: "system", time: "2026-10-16T04:10:11+00:00",
      source: "system_clock", synchronized: nil } ])
  end

  it "supports nonzero offsets without using the collector timezone" do
    expect(clock(fixture(:general).sub("+00:00", "+05:30")).records.first[:time]).to eq("2026-10-16T04:10:11+05:30")
    expect(clock(fixture(:general).sub("+00:00", "-03:30")).records.first[:time]).to eq("2026-10-16T04:10:11-03:30")
  end

  it "does not use boot or configuration timestamps as the current clock" do
    text = fixture(:general).lines.reject { |line| line.start_with?("System Information at") }.join
    expect(clock(text).status).to eq(:failed)
    expect(clock(text).records).to be_empty
  end

  it "does not choose between duplicate current clocks or timezones" do
    [ fixture(:general) + fixture(:general).lines.first, fixture(:general) + fixture(:general).lines[1] ].each do |text|
      result = clock(text)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:time]).to be_nil
    end
  end

  it "rejects invalid dates, clock values, weekday mismatches and offsets" do
    [ fixture(:general).sub("Oct 16", "Feb 30"), fixture(:general).sub("04:10:11", "24:10:11"),
      fixture(:general).sub("Fri Oct", "Mon Oct"), fixture(:general).sub("+00:00", "+24:00"),
      fixture(:general).sub("+00:00", "+00:60") ].each do |text|
      expect(clock(text)).not_to be_complete
      expect(clock(text).records.first[:time]).to be_nil
    end
  end

  it "keeps unzoned clocks and incomplete captures inconclusive" do
    text = fixture(:general).sub(" (GMT offset +00:00)", "")
    expect(clock(text).issues).to include(include(code: :clock_offset_unknown))
    expect(clock(text).records.first[:time]).to be_nil
    expect(clock(fixture(:general), complete: false)).not_to be_complete
  end

  it "retains command rejection instead of accepting preceding clock lines" do
    result = clock(fixture(:general) + "Error: Permission denied\n")
    expect(result.status).to eq(:failed)
    expect(result.records).to be_empty
    expect(clock("Unknown command\n").status).to eq(:unsupported)
  end

  it "keeps cumulative NTP updates separate from current synchronization" do
    result = ntp
    expect(result[:ntp].status).to eq(:partial)
    expect(result[:ntp].records).to eq([ { component: "system", synchronized: nil, last_sync_status: :unknown, last_sync_at: nil } ])
    expect(result[:ntp].issues).to include(include(code: :ntp_system_status_unavailable), include(code: :ntp_last_sync_offset_unknown))
    expect(result[:device_counters]).to be_complete
    expect(result[:device_counters].records.map { |row| row[:value] }).to eq([ 679, 492, 184, 679, 492, 11 ])
    expect(result[:device_counters].records).to all(include(category: :informational, discontinuity: nil, sampled_at: nil))
  end

  it "does not infer synchronization failure or success from zero or positive totals" do
    [ "0", "9000" ].each do |value|
      text = fixture(:ntp).gsub(/(?<=:)\s*\d+(?=\n)/, " #{value}")
      expect(ntp(text)[:ntp].records.first[:synchronized]).to be_nil
    end
  end

  it "isolates malformed NTP timestamps from otherwise valid counters" do
    result = ntp(fixture(:ntp).sub("00:28:10", "25:28:10"))
    expect(result[:device_counters]).to be_complete
    expect(result[:ntp].issues).to include(include(code: :invalid_ntp_time))
  end

  it "retains malformed and missing counter evidence without manufacturing zero" do
    result = ntp(fixture(:ntp).sub("679", "unknown"))[:device_counters]
    expect(result.status).to eq(:partial)
    expect(result.records.first[:value]).to be_nil
    expect(result.issues).to include(include(code: :invalid_ntp_counter))
    text = fixture(:ntp).sub("Responses Received:        492\n", "")
    expect(ntp(text)[:device_counters].issues).to include(include(code: :incomplete_ntp_counter_section))
  end

  it "drops duplicate counter identities and diagnoses unknown output" do
    text = fixture(:ntp).sub("Updates:                   184", "Requests Sent:             679\nUpdates:                   184")
    result = ntp(text)[:device_counters]
    expect(result.records.size).to eq(5)
    expect(result.issues).to include(include(code: :duplicate_identity))
    expect(ntp(fixture(:ntp) + "Future state: yes\n")[:ntp].issues).to include(include(code: :unrecognized_ntp_line))
    expect(ntp("")[:ntp].status).to eq(:failed)
    expect(ntp(fixture(:ntp), complete: false)[:device_counters]).not_to be_complete
  end

  it "rejects command errors across both NTP projections" do
    result = ntp(fixture(:ntp) + "Error: Permission denied\n")
    %i[ntp device_counters].each do |dimension|
      expect(result[dimension].status).to eq(:failed)
      expect(result[dimension].records).to be_empty
    end
  end

  %i[bgp ospf].each do |name|
    it "retains explicit #{name} disabled state without asserting neighbor health" do
      result = protocol(name, fixture("#{name}_disabled"))
      expect(result.status).to eq(:partial)
      expect(result.records).to be_empty
      expect(result.issues).to include(include(code: :protocol_disabled))
      expect(protocol(name, fixture("#{name}_disabled"), complete: false).issues).to include(include(code: :incomplete_output))
    end

    it "keeps unverified, empty and contradictory #{name} output inconclusive" do
      [ "", fixture("#{name}_menu"), "Peer State\n192.0.2.1 established\n",
        fixture("#{name}_disabled") + "Unexpected neighbors\n" ].each do |text|
        result = protocol(name, text)
        expect(result.status).to eq(:failed)
        expect(result.records).to be_empty
        expect(result.issues).to include(include(code: :"unrecognized_#{name}_output"))
      end
    end

    it "preserves command failures in #{name} output" do
      expect(protocol(name, "Unknown command\n").status).to eq(:unsupported)
      result = protocol(name, fixture("#{name}_disabled") + fixture(:command_error))
      expect(result.status).to eq(:failed)
      expect(result.records).to be_empty
    end
  end
end
