# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/policy"

RSpec.describe "CtxChecker system observation contracts" do
  def observation(name, records)
    CtxChecker::Observation.new(name: name, status: :complete, records: records)
  end

  it "keeps optional readings nil and freezes caller-owned nested data" do
    input = { component: "CPU 1", scope: +"management" }
    row = observation(:cpu, [ input ]).records.first
    expect(row[:utilization]).to be_nil
    input[:scope].replace("changed")
    expect(row[:scope]).to eq("management")
    expect(row).to be_frozen
  end

  it "retains CPU windows and scoped pools as distinct identities" do
    row = { component: "CPU 1", scope: "control", window_seconds: 5 }
    expect(observation(:cpu, [ row, row.merge(window_seconds: 60) ]).records.size).to eq(2)
    expect { observation(:cpu, [ row, row.dup ]) }.to raise_error(ArgumentError, /Duplicate/)
    expect { observation(:memory, [ { component: "pool" } ]) }.to raise_error(ArgumentError, /identity/)
  end

  it "rejects invalid percentages, fractional counters, timestamps and system enums" do
    cases = [ [ :cpu, { component: "cpu", scope: "control", utilization: 101 } ],
      [ :memory, { component: "pool", scope: "control", total_bytes: -1 } ],
      [ :temperature, { component: "sensor", value: Float::INFINITY } ],
      [ :clock, { component: "system", time: "2026-10-16T11:00:00" } ],
      [ :clock, { component: "system", time: "2026-02-30T11:00:00Z" } ],
      [ :clock, { component: "system", time: "2026-10-16T11:00:00+00:99" } ],
      [ :ntp, { component: "system", stratum: 17 } ],
      [ :ntp, { component: "peer_address", last_sync_status: :healthy } ],
      [ :ntp, { component: "peer_address", last_sync_at: "2026-10-16T11:00:00" } ],
      [ :device_counters, { component: "system", metric: "drops", value: 1.5 } ],
      [ :power, { component: "PS1", kind: :fan } ],
      [ :alarms, { component: "system", alarm_id: "summary", active: "false" } ] ]
    cases.each { |name, row| expect { observation(name, [ row ]) }.to raise_error(ArgumentError) }
  end

  it "validates declarative policies and preserves existing default interface counter limits" do
    bad = [ { resource_thresholds: { cpu: { warning: 90, critical: 80 } } },
      { resource_thresholds: { memory: { warning: 80 } } }, { required_dimensions: [ :unknown ] },
      { required_components: { power: [ "PS1", "PS1" ] } }, { max_clock_skew_seconds: -1 },
      { max_ntp_offset_ms: Float::NAN }, { device_counter_limits: { "drop" => 1.5 } },
      { temperature_thresholds: { "sensor" => { low_alarm: 90, high_alarm: 70 } } } ]
    bad.each { |options| expect { CtxChecker::Policy.new(**options) }.to raise_error(ArgumentError) }
    policy = CtxChecker::Policy.new
    expect(policy.counter_limits).to eq({})
    expect(policy.system.resource_thresholds).to be_frozen
    expect(policy.system).to be_frozen
  end
end
