# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"
require "ctx_checker/evaluator"

RSpec.describe "PAN-OS system runtime parsers" do
  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/palo_alto/#{name}.txt", __dir__))
  end

  def parse(dimension, body, complete: true)
    CtxChecker::RuntimeParser.new(platform: :palo_alto).parse(dimension, body, complete: complete)
  end

  it "shares one MP capture while preserving scope and available-memory semantics" do
    results = CtxChecker::RuntimeParser.new(platform: :palo_alto).parse_many(%i[cpu memory], fixture(:resources), complete: true)
    expect(results.values).to all(be_complete)
    expect(results[:cpu].records.first).to include(component: "management", scope: "management_plane", utilization: 16.0, window_seconds: nil)
    expect(results[:memory].records.first).to include(total_bytes: 8000 * 1024**2, used_bytes: 4000 * 1024**2, available_bytes: 4000 * 1024**2,
      utilization: 50.0, basis: :available)
  end

  it "computes documented legacy cache adjustment without equating free to available" do
    body = "Cpu(s): 1.0%us, 2.0%sy, 0.0%ni, 97.0%id, 0.0%wa, 0.0%hi, 0.0%si, 0.0%st\n" \
      "Mem: 1000k total, 800k used, 200k free, 100k buffers\nSwap: 2000k total, 100k used, 1900k free, 300k cached\n"
    expect(parse(:memory, body).records.first).to include(basis: :used_minus_cache, utilization: 40.0, used_bytes: 400 * 1024,
      free_bytes: 200 * 1024, available_bytes: 600 * 1024)
    expect(parse(:cpu, body)).to be_complete
  end

  it "does not treat missing available memory or malformed CPU as healthy measurements" do
    body = fixture(:resources).sub(" 4000.0 avail Mem", "")
    result = parse(:memory, body)
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(utilization: nil, basis: :unknown)
    result = parse(:cpu, fixture(:resources).sub("84.0 id", "-84.0 id"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:utilization]).to be_nil
    expect(parse(:cpu, fixture(:resources) + "Cpu(s): invalid\n").records).to be_empty
  end

  it "preserves binary units and rejects contradictory memory quantities" do
    body = fixture(:resources).gsub("MiB", "GiB")
    expect(parse(:memory, body).records.first[:total_bytes]).to eq(8000 * 1024**3)
    result = parse(:memory, fixture(:resources).sub("4000.0 avail Mem", "9000.0 avail Mem"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:utilization]).to be_nil
    expect(parse(:memory, fixture(:resources).sub("8000.0 total", "8000.0k total")).status).to eq(:partial)
  end

  it "keeps temperatures fans rails and PSUs independently scoped" do
    results = CtxChecker::RuntimeParser.new(platform: :palo_alto).parse_many(%i[temperature environment power], fixture(:environmentals), complete: true)
    expect(results.values).to all(be_complete)
    expect(results[:temperature].records.last).to include(value: 86.0, high_alarm: 80.0, status: :critical)
    expect(results[:environment].records).to include(include(kind: :fan, status: :critical))
    expect(results[:power].records).to include(include(kind: :power_rail), include(kind: :power_supply, present: true, status: :critical))
  end

  it "retains an intentionally absent PSU and missing supply coverage" do
    body = fixture(:environmentals).sub("Power Supply #2 True True", "Power Supply #2 False False")
    expect(parse(:power, body).records.last).to include(status: :absent, present: false)
    result = parse(:power, body.split("----Power Supplies----").first)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :power_supply_status_missing))
    expect(parse(:power, "----Thermal----\nSlot Description Alarm Degrees C\nS1 MP False 30.0\n").status).to eq(:failed)
  end

  it "preserves device-limit violations even when fan or rail alarm flags disagree" do
    body = fixture(:environmentals).sub("False 12000 2500", "False 0 2500").sub("False 12.10 11.00 13.00", "False 9.00 11.00 13.00")
    %i[environment power].each do |dimension|
      result = parse(dimension, body)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:status]).to eq(:failed)
      expect(result.issues).to include(include(code: :conflicting_environment_state))
    end
    result = parse(:power, fixture(:environmentals).sub("12.10 11.00 13.00", "-12.10 -13.00 -11.00"))
    expect(result).to be_complete
    expect(result.records.first[:status]).to eq(:ok)
    result = parse(:power, fixture(:environmentals).sub("12.10 11.00 13.00", "12.10 13.00 11.00"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:status]).to eq(:unknown)
  end

  it "isolates malformed temperature rows and removes duplicate sensor identities" do
    body = fixture(:environmentals).sub("32.50", "not-a-number")
    expect(parse(:temperature, body).status).to eq(:partial)
    expect(parse(:power, body)).to be_complete
    body = fixture(:environmentals).sub("S1 Temperature at MP False 32.50 -5.00 75.00", "S1 Temperature at MP False 32.50 -5.00 75.00\n" * 2)
    expect(parse(:temperature, body).records).not_to include(include(component: "S1/Temperature at MP"))
    expect(parse(:temperature, fixture(:environmentals) + "----Thermal----\nSlot Description Alarm Degrees C\n").status).to eq(:partial)
    expect(parse(:environment, fixture(:environmentals).sub("12000", "-12000")).status).to eq(:partial)
  end

  it "leaves exact thermal-limit equality unresolved without documented comparison semantics" do
    result = parse(:temperature, "----Thermal----\nSlot Description Alarm Degrees C Min C Max C\nS1 MP False 75.00 -5.00 75.00\n")
    expect(result.records.first).to include(value: 75.0, high_alarm: 75.0, high_comparison: nil)
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "palo_alto" },
      observed_at: Time.utc(2026, 10, 16), observations: { temperature: result })
    findings = CtxChecker::Evaluator.new.call(snapshot).findings.select { |row| row.dimension == :temperature }
    expect(findings.map(&:reason)).to include(:temperature_boundary_unknown)
    expect(findings.map(&:status)).not_to include(:pass)
  end

  it "accepts explicit clock offsets and refuses to guess local timezone abbreviations" do
    expect(parse(:clock, fixture(:clock)).records.first[:time]).to eq("2026-10-16T12:10:00+00:00")
    expect(parse(:clock, fixture(:clock).sub("UTC", "+08:00")).records.first[:time]).to eq("2026-10-16T12:10:00+08:00")
    %w[CST PST].each do |zone|
      result = parse(:clock, fixture(:clock).sub("UTC", zone))
      expect(result.status).to eq(:partial)
      expect(result.records.first[:time]).to be_nil
    end
    expect(parse(:clock, "Fri Feb 31 12:10:00 UTC 2026\n").records.first[:time]).to be_nil
  end

  it "separates global NTP state from rejected yet reachable peers" do
    result = parse(:ntp, fixture(:ntp))
    expect(result).to be_complete
    expect(result.records.first).to include(component: "system", synchronized: true, reference: "time.example.test")
    expect(result.records.last).to include(component: "peer/time2.example.test", synchronized: false)
    result = parse(:ntp, fixture(:ntp).sub("NTP synched to time.example.test\n", ""))
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(component: "system", synchronized: nil)
  end

  it "keeps legacy LOCAL fallback unsynchronized and rejects conflicting system states" do
    body = "NTP state:\nNTP synched to LOCAL\nNTP server time.example.test connected: True\n"
    expect(parse(:ntp, body).records.first[:synchronized]).to be(false)
    expect(parse(:ntp, body).records.last[:synchronized]).to be_nil
    result = parse(:ntp, fixture(:ntp) + "NTP not synched, using local clock\n")
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(component: "system"))
    result = parse(:ntp, fixture(:ntp).sub("status: synched", "status: rejected"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:synchronized]).to be_nil
    result = parse(:ntp, "NTP state:\nNTP synched to time.example.test\nNTP server time.example.test connected: False\n")
    expect(result.status).to eq(:partial)
    expect(result.records.first[:synchronized]).to be_nil
  end

  it "reads current alarms without eval or historical log inference" do
    result = parse(:alarms, fixture(:alarms))
    expect(result).to be_complete
    expect(result.records).to include(include(component: "chassis", active: false, count: 0),
      include(component: "env.s1.fan.1", active: true, severity: :unknown))
    expect(parse(:alarms, "2026/10/16 critical general Chassis alarm\n").status).to eq(:failed)
    expect(parse(:alarms, fixture(:alarms) + "chassis.alarm: { unexpected structure }\n").status).to eq(:partial)
    expect(parse(:alarms, "env.s1.fan.1: { 'alarm': True, 'alarm': False, }\n").status).to eq(:failed)
  end

  it "retains cumulative device counters without rates or guessed restart epochs" do
    result = parse(:device_counters, fixture(:global_counters))
    expect(result).to be_complete
    expect(result.records).to include(include(metric: "pkt_recv", category: :informational, value: 50000, discontinuity: nil),
      include(metric: "flow_rcv_err", category: :discard, value: 5), include(metric: "aho_lookup_error", category: :error))
    expect(result.records.flat_map(&:keys)).not_to include(:rate)
  end

  it "classifies verified security-policy drops without guessing other metric names" do
    body = "Global counters:\nname value rate severity category aspect description\n" \
      "flow_policy_deny 100 0 drop flow session Synthetic policy counter\n" \
      "flow_policy_unknown 5 0 drop flow session Unclassified test counter\nTotal counters shown: 2\n"
    result = parse(:device_counters, body)
    expect(result).to be_complete
    expect(result.records).to include(include(metric: "flow_policy_deny", category: :policy),
      include(metric: "flow_policy_unknown", category: :discard))
  end

  it "checks counter totals and requires explicit zero rather than an empty table" do
    header = "Global counters:\nname value rate severity category aspect description\n"
    expect(parse(:device_counters, header).status).to eq(:failed)
    expect(parse(:device_counters, header + "Total counters shown: 0\n")).to be_complete
    expect(parse(:device_counters, fixture(:global_counters).sub("shown: 3", "shown: 4")).status).to eq(:partial)
    result = parse(:device_counters, fixture(:global_counters).sub("flow_rcv_err 5", "flow_rcv_err -5"))
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(metric: "flow_rcv_err"))
  end

  it "preserves unsupported and incomplete boundaries for all PAN system commands" do
    { cpu: :resources, memory: :resources, temperature: :environmentals, environment: :environmentals, power: :environmentals,
      clock: :clock, ntp: :ntp, alarms: :alarms, device_counters: :global_counters }.each do |dimension, file|
      expect(parse(dimension, fixture(file), complete: false).status).to eq(:partial)
      expect(parse(dimension, "Invalid command\n").status).to eq(:unsupported)
    end
  end
end
