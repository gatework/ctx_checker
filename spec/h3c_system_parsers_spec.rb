# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"
require "ctx_checker/evaluator"

RSpec.describe "H3C system runtime parsers" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :h3c) }
  let(:dimensions) { %i[cpu memory temperature environment power clock ntp alarms] }

  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/h3c/#{name}.txt", __dir__))
  end

  def parse(name, source = fixture(name), complete: true)
    parser.parse(name, source, complete: complete)
  end

  it "parses each documented synthetic command body through the canonical observation contract" do
    dimensions.each do |name|
      result = parse(name)
      expect(result.status).to eq(:complete), "#{name}: #{result.issues.inspect}"
      expect(result.records).not_to be_empty
    end
  end

  it "retains CPU intervals and slot identity without averaging busy members away" do
    rows = parse(:cpu).records
    expect(rows.size).to eq(6)
    expect(rows.first).to include(component: "slot 1 cpu 0", scope: "system", window_seconds: 5, utilization: 12)
    expect(rows.last).to include(component: "slot 2 cpu 0", window_seconds: 300, utilization: 82)
    table = "Chassis Slot CPU Last 5 sec Last 1 min Last 5 min\n1 2 0 11% 12% 13%\n"
    expect(parse(:cpu, table).records).to include(include(component: "chassis 1 slot 2 cpu 0", utilization: 12, window_seconds: 60))
  end

  it "keeps missing and impossible CPU readings unavailable and notices truncated intervals" do
    [ "--", "101", "9" * 400 ].each do |value|
      result = parse(:cpu, fixture(:cpu).sub("12%", "#{value}%"))
      expect(result.status).to eq(:partial)
      expect(result.records.first[:utilization]).to be_nil
    end
    expect(parse(:cpu, "Slot 1 CPU 0 CPU usage:\n12% in last 5 seconds\n").status).to eq(:partial)
    expect(parse(:cpu, fixture(:cpu) + "Slot 1 CPU 0 CPU usage:\n20% in last 5 seconds\n").records)
      .not_to include(include(component: "slot 1 cpu 0", window_seconds: 5))
  end

  it "keeps CPU window coverage scoped to each component with repeated and missing windows" do
    source = "Slot 1 CPU usage:\n1% in last 5 seconds\n2% in last 1 minute\n3% in last 5 minutes\n" +
      "Slot 2 CPU usage:\n4% in last 5 seconds\n5% in last 5 seconds\n6% in last 5 minutes\n" +
      "Slot 3 CPU usage:\n"
    result = parse(:cpu, source)
    expect(result.status).to eq(:partial)
    expect(result.records.select { |row| row[:component] == "slot 1" }.map { |row| row[:window_seconds] }).to eq([ 5, 60, 300 ])
    expect(result.records.select { |row| row[:component] == "slot 2" }.map { |row| row[:window_seconds] }).to eq([ 300 ])
    expect(result.issues).to include(include(code: :missing_cpu_windows, component: "slot 2", count: 1),
      include(code: :missing_cpu_windows, component: "slot 3", count: 3), include(code: :duplicate_identity))
  end

  it "does not let repeated CPU headers restore ambiguous windows or hide absent ones" do
    text = "Slot 1 CPU usage:\n1% in last 5 seconds\n" * 32
    result = parse(:cpu, text)
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :duplicate_identity, count: 1),
      include(code: :missing_cpu_windows, component: "slot 1", count: 2))
    expect(result.issues.count { |issue| issue[:code] == :missing_cpu_windows }).to eq(1)
  end

  it "uses verified cache-adjusted application memory and preserves byte units and scope" do
    rows = parse(:memory).records
    expect(rows.first).to include(component: "slot 1", scope: "physical", utilization: 24.462890625,
      total_bytes: 2_147_483_648, used_bytes: 525_336_576, free_bytes: 1_610_612_736, available_bytes: 1_622_147_072, basis: :used_minus_cache)
    expect(rows.last[:utilization]).to be > 89
    container = fixture(:memory).sub("Memory statistics", "Container memory statistics").sub("1572864", "1000000")
    expect(parse(:memory, container).records.first).to include(scope: "container", utilization: 25, basis: :used_total, free_bytes: nil)
  end

  it "does not convert unavailable or inconsistent memory totals into healthy utilization" do
    [ fixture(:memory).sub("2097152", "0"), fixture(:memory).sub("524288", "99999999"),
      fixture(:memory).sub("524288", "--"), fixture(:memory).sub("1572864", "1") ].each do |text|
      result = parse(:memory, text)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:utilization]).to be_nil
    end
    expect(parse(:memory, fixture(:memory).sub("measured in KB", "measured in units")).status).to eq(:failed)
    expect(parse(:memory, fixture(:memory) + fixture(:memory)).records).to be_empty
    expect(parse(:memory, fixture(:memory).sub("         0      1024     10240       75.0%", "")).status).to eq(:partial)
  end

  it "requires consistent cache-adjustment evidence and does not restore ambiguous rows" do
    raw = fixture(:memory).lines.reject { |line| line.start_with?("-/+ Buffers/Cache:") }.join
    expect(parse(:memory, raw).records.first).to include(basis: :used_including_cache, utilization: 25,
      used_bytes: 536_870_912, free_bytes: 1_610_612_736)
    [ fixture(:memory).sub("513024", "513025"), fixture(:memory).sub("513024", "--"),
      fixture(:memory).sub("513024", "-1"), fixture(:memory).sub("-/+ Buffers/Cache:    513024   1584128",
        "-/+ Buffers/Cache:    513024   1584128\n-/+ Buffers/Cache:    513024   1584128\n-/+ Buffers/Cache:    513024   1584128") ].each do |text|
      result = parse(:memory, text)
      expect(result.status).to eq(:partial)
      expect(result.records.first).to include(basis: :unknown, utilization: nil)
    end
  end

  it "does not overlook a trailing slot or memory section without measurements" do
    [ "Slot 3:\n", "Memory statistics are measured in KB:\n",
      "Container memory statistics are measured in KB(Available):\nSlot 5:\n" ].each do |tail|
      result = parse(:memory, fixture(:memory) + tail)
      expect(result.status).to eq(:partial)
      expect(result.issues.map { |issue| issue[:code] }).to include(:missing_memory_sample).or include(:missing_memory_section)
    end
  end

  it "retains per-sensor alarm limits and unavailable temperatures" do
    expect(parse(:temperature).records.last).to include(component: "slot 2/hotspot 1", value: 97,
      low_alarm: nil, low_warning: 0, high_warning: 80, high_alarm: 95)
    result = parse(:temperature, fixture(:temperature).sub("hotspot 1 42", "hotspot 1 --"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:value]).to be_nil
    result = parse(:temperature, fixture(:temperature) + "1 hotspot 1 25 0 75 90 105\n")
    expect(result.records).not_to include(include(component: "slot 1/hotspot 1"))
  end

  it "checks H3C temperature boundaries from the parser through the shared evaluator" do
    { -1 => [ :fail, :warning ], 0 => [ :pass, :info ], 74 => [ :pass, :info ],
      75 => [ :fail, :warning ], 90 => [ :fail, :critical ] }.each do |value, expected|
      text = "Slot Sensor Temperature Lower Warning Alarm Shutdown\n1 hotspot 1 #{value} 0 75 90 105\n"
      observation = parse(:temperature, text)
      expect(observation.records.first).to include(low_warning: 0, high_comparison: :gte)
      snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "h3c" },
        observed_at: Time.utc(2026, 10, 16), observations: { temperature: observation })
      finding = CtxChecker::Evaluator.new.call(snapshot).findings.find { |row| row.dimension == :temperature }
      expect([ finding.status, finding.severity ]).to eq(expected)
    end
  end

  it "retains fan failures and absence independently across slots and supported layouts" do
    expect(parse(:environment).records.map { |row| row[:status] }).to eq(%i[ok failed absent])
    expect(parse(:environment, "Fan Frame 0 State: Normal\n").records.first).to include(component: "system/fan 0", status: :ok)
    expect(parse(:environment, "Fan No. State Speed\n0 Fault 0\n").records.first[:status]).to eq(:failed)
    result = parse(:environment, "Fan 1:\nState: Normal\nState: Fault\nState: Normal\n")
    expect(result.status).to eq(:partial)
    expect(result.records.first[:status]).to eq(:unknown)
    expect(parse(:environment, "Fan 1:\n").status).to eq(:partial)
  end

  it "keeps absent supplies distinct from failed supplies and unknown readings" do
    rows = parse(:power).records
    expect(rows[0]).to include(component: "slot 1/power 1", present: true, status: :ok, watts: 96)
    expect(rows[1]).to include(present: false, status: :absent, watts: nil)
    expect(rows[2]).to include(component: "slot 2/power 1", present: true, status: :failed, watts: 0)
    expect(parse(:power, "Power 0 State: Normal\n").records.first[:watts]).to be_nil
    result = parse(:power, fixture(:power).sub("96.0", "-96.0"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:watts]).to be_nil
    expect(parse(:power, fixture(:power).sub("1 Normal AC", "1 Novel AC")).status).to eq(:partial)
  end

  it "does not hide an empty middle or trailing hardware scope behind earlier successful records" do
    { environment: "Slot 99:\n", power: "Slot 99:\nPowerID State Mode Current(A) Voltage(V) Power(W)\n",
      temperature: "Chassis 99:\nSlot Sensor Temperature Lower Warning Alarm Shutdown\n" }.each do |name, tail|
      expect(parse(name, fixture(name) + tail).status).to eq(:partial)
      expect(parse(name, tail + fixture(name)).status).to eq(:partial) unless name == :temperature
    end
    text = "Chassis 99:\nChassis 1:\n" + fixture(:temperature)
    expect(parse(:temperature, text).status).to eq(:partial)
  end

  it "normalizes an explicit clock offset without inferring synchronization" do
    row = parse(:clock).records.first
    expect(row).to include(time: "2026-10-16T05:05:09.250Z", synchronized: nil, source: nil)
    expect(parse(:clock, "05:05:09 UTC Fri 10/16/2026\n").records.first[:time]).to eq("2026-10-16T05:05:09.000Z")
  end

  it "leaves unresolved clock zones, daylight saving and invalid calendar dates unknown" do
    [ fixture(:clock).lines.first, fixture(:clock) + "Summer Time : DST 06:00:00 08/01 06:00:00 09/01 01:00:00\n",
      fixture(:clock).sub("10/16/2026", "02/30/2026"), fixture(:clock).sub("08:00:00", "08:75:00") ].each do |text|
      result = parse(:clock, text)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:time]).to be_nil
    end
    expect(parse(:clock, fixture(:clock) + fixture(:clock)).records).to be_empty
  end

  it "keeps NTP status, server, reference, leap and signed offset separate" do
    row = parse(:ntp).records.first
    expect(row).to include(component: "system", synchronized: true, stratum: 3,
      peer_address: "192.0.2.123", reference: "192.0.2.123", offset_ms: -0.125, leap: 0)
    text = "Clock status: unsynchronized\n\nClock stratum: 16\nReference clock ID: none\n"
    expect(parse(:ntp, text).records.first).to include(synchronized: false, stratum: 16, peer_address: nil, reference: nil, offset_ms: nil)
    text = "Clock status: synchronized\nClock jitter: 9.000 s\nSystem peer: LOCAL(0)\n"
    expect(parse(:ntp, text).records.first).to include(peer_address: "LOCAL(0)", offset_ms: nil, synchronized: false)
    expect(parse(:ntp, "Clock status: synchronized\nReference clock ID: 127.127.1.0\n").records.first[:synchronized]).to be(false)
    expect(parse(:ntp, "Clock status: synchronized\nSystem peer: 192.0.2.123\nReference clock ID: 127.127.1.0\n").records.first[:synchronized]).to be(true)
    expect(parse(:ntp, "Clock status: synchronized\nClock stratum: 1\nReference clock ID: GPS\n").records.first[:synchronized]).to be(true)
  end

  it "requires an explicitly successful NTP-to-local-clock sync state when the field is present" do
    field = "Sync state from NTP server to local clock: "
    expect(parse(:ntp, fixture(:ntp) + field + "clock synced\n").status).to eq(:complete)
    [ "clock not synced", "clock unsynced" ].each do |state|
      result = parse(:ntp, fixture(:ntp) + field + state + "\n")
      expect(result.status).to eq(:partial)
      expect(result.records.first[:synchronized]).to be(false)
    end
    [ "pending", "", "clock synced\n" + field + "clock synced" ].each do |state|
      result = parse(:ntp, fixture(:ntp) + field + state + "\n")
      expect(result.status).to eq(:partial)
      expect(result.records.first[:synchronized]).to be_nil
    end
    result = parse(:ntp, "Clock status: unsynchronized\n" + field + "pending\n")
    expect(result.records.first[:synchronized]).to be(false)
  end

  it "does not pick one of conflicting NTP fields or fabricate a status from other fields" do
    result = parse(:ntp, fixture(:ntp) + "Clock status: unsynchronized\nClock status: synchronized\n")
    expect(result.status).to eq(:partial)
    expect(result.records.first[:synchronized]).to be_nil
    result = parse(:ntp, fixture(:ntp).sub("Clock stratum: 3", "Clock stratum: 17"))
    expect(result.records.first[:stratum]).to be_nil
    expect(parse(:ntp, "Clock stratum: 2\n").status).to eq(:partial)
  end

  it "preserves active alarm severity without exposing free-form alarm messages" do
    result = parse(:alarms)
    expect(result.records.map { |row| row[:severity] }).to eq(%i[warning critical])
    expect(result.records.first).to include(alarm_id: "51", active: true, count: 1)
    expect(result.to_h.to_s).not_to include("configured warning limit")
    expect(parse(:alarms, "Seq Level Time Info\n").status).to eq(:failed)
    expect(parse(:alarms, "No active alarms\n").records.first).to include(active: false, count: 0)
    expect(parse(:alarms, fixture(:alarms) + "No active alarms\n").status).to eq(:partial)
    expect(parse(:alarms, fixture(:alarms).sub("51 Warning", "51 Novel")).status).to eq(:partial)
  end

  it "preserves unsupported commands, errors, unknown lines, pagination and incomplete evidence" do
    dimensions.each do |name|
      expect(parse(name, "Unrecognized command\n").status).to eq(:unsupported)
      expect(parse(name, "Error: permission denied\n").status).to eq(:failed)
      expect(parse(name, "\n").status).to eq(:failed)
      expect(parse(name, fixture(name) + "unknown appended line\n").status).to eq(:partial)
      expect(parse(name, fixture(name) + "--More--\n").status).to eq(:partial)
      expect(parse(name, complete: false).status).to eq(:partial)
    end
  end
end
