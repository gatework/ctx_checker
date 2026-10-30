# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/hillstone/parsers/show_clock"
require "ctx_checker/hillstone/parsers/show_ntp_status"
require "ctx_checker/hillstone/parsers/show_ip_bgp_summary"
require "ctx_checker/hillstone/parsers/show_ip_ospf_neighbor"
require "ctx_checker/evaluator"

RSpec.describe "StoneOS protocol and time evidence" do
  # 加载脱敏设备样本，无需实时连接。
  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/hillstone/#{name}.txt", __dir__))
  end

  # 独立验证命令语法，不依赖平台策略选择。
  def parse(name, text, complete: true)
    klass = { clock: CtxChecker::Hillstone::Parsers::ShowClock, ntp: CtxChecker::Hillstone::Parsers::ShowNtpStatus,
      bgp: CtxChecker::Hillstone::Parsers::ShowIpBgpSummary, ospf: CtxChecker::Hillstone::Parsers::ShowIpOspfNeighbor }.fetch(name)
    klass.parse(text, complete: complete)
  end

  it "does not infer a UTC offset from the observed named timezone" do
    result = parse(:clock, fixture(:clock))
    expect(result.status).to eq(:partial)
    expect(result.records).to eq([ { component: "system", time: nil, source: "system_clock", synchronized: nil } ])
    expect(result.issues).to include(include(code: :clock_offset_unknown))
  end

  it "uses explicit UTC offsets without a host timezone dependency" do
    result = parse(:clock, fixture(:clock).sub("China", "GMT+08:00"))
    expect(result).to be_complete
    expect(result.records.first[:time]).to eq("2026-10-16T11:48:37+08:00")
    expect(parse(:clock, fixture(:clock).sub("China", "UTC")).records.first[:time]).to eq("2026-10-16T11:48:37+00:00")
  end

  it "rejects duplicate zones, duplicate clocks, impossible dates and inconsistent weekdays" do
    base = fixture(:clock).sub("China", "+0800")
    [ base + "Current time zone: UTC\n", base + base.lines.last,
      base.sub("2026-10-16", "2026-02-30"), base.sub("11:48:37", "24:48:37"),
      base.sub("Friday", "Monday"), base.sub("+0800", "+0860") ].each do |text|
      result = parse(:clock, text)
      expect(result).not_to be_complete
      expect(result.records.map { |row| row[:time] }).to all(be_nil)
    end
  end

  it "keeps incomplete and unrecognized clock input inconclusive" do
    expect(parse(:clock, fixture(:clock).sub("China", "UTC"), complete: false)).not_to be_complete
    expect(parse(:clock, "2026-10-16 11:48:37 Friday\n").records.first[:time]).to be_nil
    expect(parse(:clock, "11:48:37\n").status).to eq(:failed)
  end

  it "retains failed NTP attempts without asserting the current system synchronization state" do
    result = parse(:ntp, fixture(:ntp_status))
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(component: "system", synchronized: nil)
    expect(result.records.drop(1)).to all(include(synchronized: nil, last_sync_status: :failed, last_sync_at: nil))
    expect(result.records.map { |row| row[:component] }).to eq([ "system", "peer/trust-vr/ntp.example.net", "peer/mgt-vr/192.0.2.20" ])
    expect(result.issues).to include(include(code: :ntp_system_status_unavailable), include(code: :ntp_last_sync_offset_unknown))
  end

  it "recognizes the observed successful attempt without declaring current system synchronization" do
    result = parse(:ntp, fixture(:ntp_status_mixed))
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(component: "system", synchronized: nil)
    expect(result.records[1]).to include(last_sync_status: :succeeded, last_sync_at: nil, synchronized: nil)
    expect(result.records[2]).to include(last_sync_status: :failed, last_sync_at: nil, synchronized: nil)
    expect(result.issues).not_to include(include(code: :unknown_ntp_last_sync_status))
  end

  it "reports the captured peer failures separately from unavailable system sync and clock skew" do
    observations = { ntp: :ntp_status, clock: :clock }.to_h do |dimension, sample|
      result = parse(dimension, fixture(sample))
      records = result.records.map { |row| row.merge(source_complete: result.complete?) }
      [ dimension, CtxChecker::Observation.new(name: dimension, status: result.status, records: records, issues: result.issues) ]
    end
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "hillstone" },
      observed_at: Time.utc(2026, 10, 16, 3, 48, 37), observations: observations)
    findings = CtxChecker::Evaluator.new.call(snapshot).findings.select { |row| %i[clock ntp].include?(row.dimension) }
    expect(findings.map { |row| [ row.reason, row.status ] }).to eq([
      [ :clock_time_unavailable, :unknown ], [ :ntp_synchronization, :unknown ],
      [ :ntp_last_sync_failed, :fail ], [ :ntp_last_sync_failed, :fail ]
    ])
    expect(findings.last(2).map(&:severity)).to eq(%i[warning warning])
  end

  it "keeps configuration-only NTP status unknown even when a preferred peer exists" do
    text = "ntp client is enabled, authentication is enabled\n" \
      "ntp query-interval is 3, max-adjustment time is 5\n" \
      "ntp server 192.0.2.20, key 1, prefer\n"
    result = parse(:ntp, text)
    expect(result.records.first[:synchronized]).to be_nil
    expect(result.records.last).to include(peer_address: "192.0.2.20", synchronized: nil, last_sync_status: :unknown)
    expect(result).not_to be_complete
  end

  it "records explicitly disabled NTP without assuming the clock is synchronized" do
    result = parse(:ntp, "ntp client is disabled, authentication is disabled\n")
    expect(result).to be_complete
    expect(result.records).to eq([ { component: "system", synchronized: false } ])
  end

  it "does not classify unobserved attempt labels as synchronization success" do
    result = parse(:ntp, fixture(:ntp_status).sub("(Error)", "(FutureStatus)"))
    expect(result.records[1]).to include(last_sync_status: :unknown, synchronized: nil)
    expect(result.issues).to include(include(code: :unknown_ntp_last_sync_status))
  end

  it "does not accept invalid peer identities or rollover timestamps" do
    [ fixture(:ntp_status).sub("ntp.example.net", "999.999.999.999"),
      fixture(:ntp_status).sub("ntp.example.net", "bad_host"),
      fixture(:ntp_status).sub("ntp.example.net", "ntp.example.net.."),
      fixture(:ntp_status).sub("11:45:20", "24:45:20"),
      fixture(:ntp_status).sub("2026-10-16", "2026-02-30") ].each do |text|
      result = parse(:ntp, text)
      expect(result).not_to be_complete
      expect(result.records.count { |row| row[:last_sync_status] == :failed }).to eq(1)
    end
  end

  it "removes ambiguous peer identities and does not select one of duplicate client states" do
    text = fixture(:ntp_status) + fixture(:ntp_status).lines.last
    result = parse(:ntp, text)
    expect(result.records.size).to eq(2)
    expect(result.issues).to include(include(code: :duplicate_identity))
    conflicting = "ntp client is disabled, authentication is disabled\nntp client is enabled, authentication is disabled\n"
    expect(parse(:ntp, conflicting).records.first[:synchronized]).to be_nil
  end

  it "keeps NTP header loss, unknown lines and incomplete capture visible" do
    no_header = fixture(:ntp_status).lines.reject { |line| line.start_with?("ntp client") }.join
    expect(parse(:ntp, no_header)).not_to be_complete
    expect(parse(:ntp, fixture(:ntp_status) + "new metric\n").issues).to include(include(code: :unrecognized_ntp_line))
    expect(parse(:ntp, "ntp client is disabled, authentication is disabled\n", complete: false)).not_to be_complete
  end

  it "distinguishes explicitly unconfigured BGP from an empty or unfamiliar capture" do
    result = parse(:bgp, fixture(:bgp_unconfigured))
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :protocol_not_configured))
    expect(parse(:bgp, "").status).to eq(:failed)
    expect(parse(:bgp, "BGP neighbor table\n").status).to eq(:failed)
    expect(parse(:bgp, fixture(:bgp_unconfigured), complete: false)).not_to be_complete
  end

  it "does not mistake an empty OSPF body or Cisco neighbor grammar for verified StoneOS evidence" do
    expect(parse(:ospf, "").status).to eq(:failed)
    text = "Neighbor ID Pri State Dead Time Address Interface\n192.0.2.1 1 FULL/DR 00:00:30 192.0.2.2 eth0\n"
    result = parse(:ospf, text)
    expect(result.status).to eq(:failed)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :unrecognized_ospf_output))
  end

  it "preserves command rejection for every command parser" do
    %i[clock ntp bgp ospf].each do |name|
      result = parse(name, "Unrecognized command\n")
      expect(result.status).to eq(:unsupported)
      expect(result.records).to be_empty
    end
  end

  %i[clock ntp bgp ospf].each do |name|
    it "rejects a StoneOS caret error in #{name} output without preserving preceding records" do
      body = { clock: fixture(:clock).sub("China", "UTC"), ntp: fixture(:ntp_status),
        bgp: fixture(:bgp_unconfigured), ospf: "" }.fetch(name)
      result = parse(name, body + "                         ^-----incomplete command\n")
      expect(result.status).to eq(:failed)
      expect(result.records).to be_empty
      expect(result.issues).to include(include(code: :command_error))
    end
  end
end
