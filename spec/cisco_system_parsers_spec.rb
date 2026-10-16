# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"

RSpec.describe "Cisco system runtime parsers" do
  def fixture(platform, name)
    File.read(File.expand_path("fixtures/ctx_checker/#{platform}/#{name}.txt", __dir__))
  end

  def parse(dimension, text, platform: :cisco_ios, complete: true)
    CtxChecker::RuntimeParser.new(platform: platform).parse(dimension, text, complete: complete)
  end

  it "retains IOS CPU windows and keeps the interrupt percentage inside the total" do
    result = parse(:cpu, fixture(:cisco_ios, :cpu))
    expect(result).to be_complete
    expect(result.records.map { |row| row[:utilization] }).to eq([ 17, 13, 9 ])
    expect(result.records.first).to include(scope: "ios_processes", window_seconds: 5, interrupt_utilization: 4)
    invalid = parse(:cpu, fixture(:cisco_ios, :cpu).sub("17%", "170%"))
    expect(invalid.status).to eq(:partial)
    expect(invalid.records.first[:utilization]).to be_nil
    expect(parse(:cpu, fixture(:cisco_ios, :cpu).sub("17%/4%", "17%/40%")).status).to eq(:partial)
  end

  it "retains separate memory pools and rejects inconsistent byte accounting" do
    result = parse(:memory, fixture(:cisco_ios, :memory))
    expect(result).to be_complete
    expect(result.records.map { |row| row[:utilization] }).to eq([ 25, 20 ])
    expect(result.records.first).to include(total_bytes: 1_000_000, basis: :used_total)
    result = parse(:memory, "Processor Pool Total: 100 Used: 80 Free: 30\n")
    expect(result.status).to eq(:partial)
    expect(result.records.first[:utilization]).to be_nil
  end

  it "splits one NX resources output without confusing idle, load average or kernel cache" do
    parser = CtxChecker::RuntimeParser.new(platform: :cisco_nxos)
    results = parser.parse_many(%i[cpu memory], fixture(:cisco_nxos, :resources), complete: true)
    expect(results.values).to all(be_complete)
    expect(results[:cpu].records.first).to include(utilization: 10, window_seconds: 1)
    expect(results[:memory].records.first).to include(utilization: 36.8, total_bytes: 1_024_000_000, basis: :used_minus_cache)
    expect(results[:cpu].evidence).to eq(results[:memory].evidence)
  end

  it "retains NX memory alarms and distinguishes corrected memory usage from missing cache" do
    text = fixture(:cisco_nxos, :resources)
    result = parse(:memory, "#{text}Current memory status: Critical\n", platform: :cisco_nxos)
    expect(result).to be_complete
    expect(result.records.first).to include(status: :critical, basis: :used_minus_cache)
    expect(result.records.first).to include(used_bytes: 376_832_000, available_bytes: 647_168_000)
    repeated = "#{text}Current memory status: Critical\nCurrent memory status: OK\n"
    expect(parse(:memory, repeated, platform: :cisco_nxos).records.first[:status]).to eq(:critical)
    no_cache = text.lines.reject { |line| line.include?("buffers") }.join
    expect(parse(:memory, no_cache, platform: :cisco_nxos).records.first).to include(basis: :used_including_cache, utilization: 40)
    invalid_cache = text.sub("30000K cache", "900000K cache")
    expect(parse(:memory, invalid_cache, platform: :cisco_nxos).status).to eq(:partial)
    expect(parse(:cpu, invalid_cache, platform: :cisco_nxos)).to be_complete
    expect(parse(:memory, "#{text}Current memory status: new-state\n", platform: :cisco_nxos).status).to eq(:partial)
    status_only = parse(:memory, "Current memory status: Critical\n", platform: :cisco_nxos)
    expect(status_only.status).to eq(:partial)
    expect(status_only.records.first).to include(status: :critical, utilization: nil)
    multicore = "#{text}CPU0 states : 2.0% user, 3.0% kernel, 95.0% idle\n"
    expect(parse(:cpu, multicore, platform: :cisco_nxos).records).to include(include(component: "cpu 0", utilization: 5))
  end

  it "keeps missing NX resources separate and refuses impossible CPU percentages" do
    text = "CPU states : 5.0% user, 5.0% kernel, 190.0% idle\n"
    expect(parse(:cpu, text, platform: :cisco_nxos).status).to eq(:partial)
    expect(parse(:memory, text, platform: :cisco_nxos).status).to eq(:failed)
  end

  it "models Catalyst fans, sensor thresholds and missing input power independently" do
    text = fixture(:cisco_ios, :environment)
    %i[environment temperature power].each { |dimension| expect(parse(dimension, text)).to be_complete }
    expect(parse(:temperature, text).records.first).to include(component: "switch 2/inlet", value: 24, high_warning: 45, high_alarm: 55)
    expect(parse(:environment, text).records).to include(include(kind: :fan, status: :failed), include(status: :absent))
    expect(parse(:power, text).records.first).to include(status: :failed, capacity_watts: 350)
    power_conflict = text.sub("OK               Good     Good", "OK               Bad      Good")
    expect(parse(:power, power_conflict).records.last[:status]).to eq(:failed)
    state_conflict = text.sub("Temperature State: GREEN", "Temperature State: RED\nTemperature State: GREEN")
    expect(parse(:temperature, state_conflict).status).to eq(:partial)
    expect(parse(:temperature, state_conflict).records.first[:status]).to eq(:critical)
  end

  it "supports ASR sensor tables without converting a fan speed percentage into healthy" do
    text = fixture(:cisco_ios, :environment_asr)
    %i[environment temperature power].each { |dimension| expect(parse(dimension, text)).to be_complete }
    expect(parse(:environment, text).records).to include(include(kind: :fan, status: :unknown))
    expect(parse(:power, text).records.first).to include(kind: :power_rail, status: :critical)
  end

  it "retains NX sensor thresholds, per-module identities and hardware clock state" do
    text = fixture(:cisco_nxos, :environment)
    %i[environment temperature power].each do |dimension|
      expect(parse(dimension, text, platform: :cisco_nxos)).to be_complete
    end
    expect(parse(:temperature, text, platform: :cisco_nxos).records.last).to include(component: "2/CPU (s2)", value: 92, high_warning: 90, high_alarm: 100, high_comparison: :gt)
    expect(parse(:environment, text, platform: :cisco_nxos).records).to include(include(kind: :clock, status: :absent))
    expect(parse(:power, text, platform: :cisco_nxos).records.last).to include(status: :failed, watts: 0)
    %w[Temperature Fan Power\ Supply].each do |section|
      dimension = { "Temperature" => :temperature, "Fan" => :environment, "Power Supply" => :power }.fetch(section)
      expect(parse(dimension, "#{text}#{section}:\n", platform: :cisco_nxos).status).to eq(:partial)
    end
  end

  it "degrades negative or nonfinite CLI readings without exceptions or erased faults" do
    huge = "9" * 400
    [ "-10", huge ].each do |value|
      text = "Power Supply:\nPower Actual Total\nSupply Model Output Capacity Status\n1 TEST #{value} W 100 W Failed\n"
      result = parse(:power, text, platform: :cisco_nxos)
      expect(result.status).to eq(:partial)
      expect(result.records.first).to include(watts: nil, capacity_watts: 100, status: :failed)
      expect(result.issues).to include(include(code: :invalid_numeric_value))
    end
    [ :cisco_ios, :cisco_nxos ].each do |platform|
      text = fixture(platform, :environment)
      text = platform == :cisco_ios ? text.sub("24 Degree", "#{huge} Degree") : text.sub("92      Minor", "#{huge}      Minor")
      result = parse(:temperature, text, platform: platform)
      expect(result.status).to eq(:partial)
      expect(result.records).to include(include(value: nil))
    end
    ntp = fixture(:cisco_ios, :ntp).sub("-2.5000 msec", "#{huge} msec")
    expect(parse(:ntp, ntp).status).to eq(:partial)
    expect(parse(:ntp, ntp).records.first[:offset_ms]).to be_nil
  end

  it "does not interpret NX unavailable threshold sentinels as real Celsius limits" do
    text = "Temperature:\nModule Sensor MajorThresh MinorThres CurTemp Status\n1 Intake -127 -127 25 Ok\n"
    result = parse(:temperature, text, platform: :cisco_nxos)
    expect(result).to be_complete
    expect(result.records.first).to include(high_alarm: nil, high_warning: nil, value: 25)
  end

  it "does not let a healthy fan stand in for missing temperature or power output" do
    expect(parse(:environment, "Switch 1 FAN 1 is OK\n")).to be_complete
    expect(parse(:temperature, "Switch 1 FAN 1 is OK\n").status).to eq(:failed)
    expect(parse(:power, "Switch 1 FAN 1 is OK\n").status).to eq(:failed)
    changed = fixture(:cisco_nxos, :environment).sub("92      Minor", "invalid      Minor")
    expect(parse(:temperature, changed, platform: :cisco_nxos).status).to eq(:partial)
    expect(parse(:power, changed, platform: :cisco_nxos)).to be_complete
  end

  it "uses explicit clock offsets and never treats the configured source as proven sync" do
    text = "09:02:03.125 UTC Fri Oct 16 2026\nTime source is NTP\n"
    %i[cisco_ios cisco_nxos].each do |platform|
      row = parse(:clock, text, platform: platform).records.first
      expect(row).to include(time: "2026-10-16T09:02:03.125+00:00", source: "NTP", synchronized: nil)
    end
    expect(parse(:clock, text.sub("UTC", "CST")).records.first[:time]).to be_nil
    expect(parse(:clock, text.sub("UTC", "+9999")).records.first[:time]).to be_nil
    expect(parse(:clock, text.sub("09:02:03", "24:02:03")).records.first[:time]).to be_nil
    expect(parse(:clock, "*#{text}").records.first[:synchronized]).to be(false)
    expect(parse(:clock, text.sub("Oct 16", "Feb 30")).status).to eq(:partial)
  end

  it "reads IOS NTP offset milliseconds and exact negative synchronization status" do
    result = parse(:ntp, fixture(:cisco_ios, :ntp))
    expect(result).to be_complete
    expect(result.records.first).to include(synchronized: true, stratum: 3, offset_ms: -2.5, reference: "192.0.2.20")
    expect(parse(:ntp, "Clock is unsynchronized, stratum 16, reference is 0.0.0.0\n").records.first[:synchronized]).to be(false)
  end

  it "uses NX selected-peer evidence and detects malformed, duplicate or truncated peers" do
    text = fixture(:cisco_nxos, :ntp)
    result = parse(:ntp, text, platform: :cisco_nxos)
    expect(result).to be_complete
    expect(result.records.first).to include(synchronized: true, stratum: 3, peer: "192.0.2.20")
    no_selected = parse(:ntp, text.sub("*192", "=192"), platform: :cisco_nxos)
    expect(no_selected.records.first[:synchronized]).to be(false)
    expect(parse(:ntp, text.sub("=192", "*192"), platform: :cisco_nxos).status).to eq(:partial)
    expect(parse(:ntp, text.sub("Total peers : 2", "Total peers : 3"), platform: :cisco_nxos).records.first[:synchronized]).to be_nil
    expect(parse(:ntp, "Total peers : 0\n", platform: :cisco_nxos).records.first[:synchronized]).to be(false)
    expect(parse(:ntp, "Total peers : 0\n", platform: :cisco_nxos, complete: false).records.first[:synchronized]).to be_nil
    expect(parse(:ntp, "Distribution : Disabled\nLast operational state: No session\n", platform: :cisco_nxos).status).to eq(:failed)
  end

  it "reports active IOS alarms and only accepts an explicit complete zero summary" do
    result = parse(:alarms, fixture(:cisco_ios, :alarms))
    expect(result).to be_complete
    expect(result.records.map { |row| row[:severity] }).to eq(%i[critical warning])
    clear = parse(:alarms, "System Totals  Critical: 0  Major: 0  Minor: 0\n")
    expect(clear).to be_complete
    expect(clear.records.first).to include(active: false, count: 0)
    inconsistent = parse(:alarms, fixture(:cisco_ios, :alarms).sub("Critical: 1", "Critical: 0"))
    expect(inconsistent.status).to eq(:partial)
    expect(parse(:alarms, "", platform: :cisco_nxos).status).to eq(:unsupported)
  end

  it "preserves device counter labels and does not mix IPv4 with later ICMP sections" do
    %i[cisco_ios cisco_nxos].each do |platform|
      result = parse(:device_counters, fixture(platform, :device_counters), platform: platform)
      expect(result).to be_complete
      expect(result.records.map { |row| row[:component] }.uniq).to eq([ "ipv4/control_plane" ])
      expect(result.records.map { |row| row[:discontinuity] }).to all(be_nil)
      expect(result.records).to include(include(metric: "checksum_errors", value: platform == :cisco_ios ? 2 : 1))
      expect(result.records).not_to include(include(value: 100), include(value: 10))
    end
    expect(parse(:device_counters, fixture(:cisco_ios, :device_counters)).records).to include(include(category: :policy, metric: "unicast_rpf"))
  end

  it "rejects malformed device counters, duplicates, CLI errors and incomplete output" do
    %i[cisco_ios cisco_nxos].each do |platform|
      text = fixture(platform, :device_counters)
      broken = platform == :cisco_ios ? text.sub("2 checksum errors", "-2 checksum errors") : text.sub("Bad checksum: 1", "Bad checksum: -1")
      expect(parse(:device_counters, broken, platform: platform).status).to eq(:partial)
      expect(parse(:device_counters, text, platform: platform, complete: false).status).to eq(:partial)
      expect(parse(:device_counters, "% Invalid command\n", platform: platform).status).to eq(:unsupported)
      expect(parse(:device_counters, "% Error: denied\n", platform: platform).status).to eq(:failed)
    end
    expect(parse(:device_counters, "Errors:\nBad checksum: 0\n", platform: :cisco_nxos).status).to eq(:failed)
    expect(parse(:device_counters, "IP statistics:\nRcvd: 0 format errors\n").status).to eq(:partial)
    expect(parse(:device_counters, "IP Software Processed Traffic Statistics\nErrors:\nBad checksum: 0\n", platform: :cisco_nxos).status).to eq(:partial)
    repeated = fixture(:cisco_ios, :cpu) * 2
    expect(parse(:cpu, repeated).records).to be_empty
    expect(parse(:cpu, repeated).status).to eq(:partial)
  end
end
