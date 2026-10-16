# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/evaluator"

RSpec.describe "CtxChecker system health assessment" do
  let(:sample_time) { Time.utc(2026, 10, 16, 3) }
  let(:target) { { host: "192.0.2.1", platform: "h3c" } }

  def snapshot(name, records, status: :complete, time: sample_time, evidence: [])
    observation = CtxChecker::Observation.new(name: name, status: status, records: records, evidence: evidence)
    CtxChecker::Snapshot.new(target: target, observed_at: time, observations: { name => observation })
  end

  def assess(name, records, policy: CtxChecker::Policy.new, previous: nil, **options)
    CtxChecker::Evaluator.new(policy: policy).call(snapshot(name, records, **options), previous: previous).findings.select { |row| row.dimension == name }
  end

  it "assesses every CPU window independently and retains scoped measurements" do
    rows = [ { component: "slot 1", scope: "control", window_seconds: 5, utilization: 96, interrupt_utilization: 10 },
      { component: "slot 1", scope: "control", window_seconds: 60, utilization: 20 },
      { component: "slot 2", scope: "control", window_seconds: 5, utilization: 82 } ]
    results = assess(:cpu, rows)
    expect(results.map(&:status)).to eq(%i[fail pass fail])
    expect(results.map(&:severity)).to eq(%i[critical info warning])
    expect(results.first.actual[:utilization]).to eq(96)
    expect(results.first.entity).to include(scope: "control", window_seconds: 5)
  end

  it "never adds interrupt CPU to total and rejects impossible subsets" do
    row = { component: "system", scope: "ios", utilization: 70, interrupt_utilization: 60 }
    expect(assess(:cpu, [ row ]).first.status).to eq(:pass)
    expect(assess(:cpu, [ row.merge(interrupt_utilization: 90) ]).first.reason).to eq(:resource_measurements_inconsistent)
  end

  it "requires meaningful memory accounting rather than calling reclaimable cache a failure" do
    row = { component: "system", scope: "management", utilization: 99, total_bytes: 1000, used_bytes: 990, basis: :used_including_cache }
    expect(assess(:memory, [ row ]).first.status).to eq(:unknown)
    expect(assess(:memory, [ row.merge(basis: :available, available_bytes: 10) ]).first.severity).to eq(:critical)
    expect(assess(:memory, [ row.merge(basis: :used_minus_cache, used_bytes: 300, utilization: 30) ]).first.status).to eq(:pass)
    expect(assess(:memory, [ row.merge(basis: :used_total, utilization: 30) ]).first.reason).to eq(:resource_measurements_inconsistent)
    expect(assess(:memory, [ row.merge(basis: :used_total, used_bytes: 1200) ]).first.reason).to eq(:resource_measurements_inconsistent)
    expect(assess(:memory, [ row.merge(basis: nil) ]).first.status).to eq(:unknown)
    expect(assess(:memory, [ row.merge(status: :critical) ]).map(&:status)).to eq(%i[fail unknown])
  end

  it "accepts declared resource policy and never certifies a partial normal sample" do
    row = { component: "system", scope: "control", utilization: 75 }
    policy = CtxChecker::Policy.new(resource_thresholds: { cpu: { warning: 70, critical: 90 } })
    expect(assess(:cpu, [ row ], policy: policy, status: :partial).first.status).to eq(:fail)
    expect(assess(:cpu, [ row ], status: :partial).first.status).to eq(:unknown)
    expect(assess(:cpu, [ row.merge(utilization: nil) ]).first.status).to eq(:unknown)
  end

  it "uses device Celsius thresholds with inclusive boundaries and no universal temperature guess" do
    row = { component: "slot 1 inlet", value: 60, high_warning: 60, high_alarm: 80, high_comparison: :gt }
    expect(assess(:temperature, [ row ]).first.status).to eq(:pass)
    expect(assess(:temperature, [ row.merge(value: 61) ]).first.severity).to eq(:warning)
    expect(assess(:temperature, [ row.merge(value: 81) ]).first.severity).to eq(:critical)
    expect(assess(:temperature, [ row.merge(high_comparison: :gte) ]).first.status).to eq(:fail)
    expect(assess(:temperature, [ row.merge(high_comparison: nil) ]).first.status).to eq(:unknown)
    expect(assess(:temperature, [ row.merge(value: 120, status: :absent) ]).map(&:status)).to eq(%i[unknown fail])
    expect(assess(:temperature, [ row.slice(:component, :value) ]).first.status).to eq(:unknown)
    expect(assess(:temperature, [ { component: "sensor", status: :ok } ]).first.status).to eq(:pass)
  end

  it "preserves explicit temperature alarms and reports contradictory or invalid limits" do
    row = { component: "sensor", value: 40, high_warning: 60, high_alarm: 80, status: :critical }
    results = assess(:temperature, [ row ])
    expect(results.map(&:status)).to eq(%i[fail pass unknown])
    expect(assess(:temperature, [ row.merge(high_warning: 90) ]).map(&:status)).to eq(%i[fail unknown])
    expect(assess(:temperature, [ row.merge(value: 90, status: :ok) ]).map(&:status)).to eq(%i[fail unknown])
  end

  it "matches temperature policy to one exact sensor without hiding device alarms" do
    policy = CtxChecker::Policy.new(temperature_thresholds: { "inlet" => { high_warning: 50 } })
    rows = [ { component: "inlet", value: 55 }, { component: "outlet", value: 55 } ]
    expect(assess(:temperature, rows, policy: policy).map(&:status)).to eq(%i[fail unknown])
    expect(assess(:temperature, [ { component: "inlet", status: :critical } ], policy: policy).first.status).to eq(:fail)
  end

  it "distinguishes optional absent power supplies from required supplies and failed rails" do
    rows = [ { component: "PS1", kind: :power_supply, status: :ok, present: true },
      { component: "PS2", kind: :power_supply, status: :absent, present: false },
      { component: "12V", kind: :power_rail, status: :failed } ]
    expect(assess(:power, rows).map(&:status)).to eq(%i[pass not_applicable fail])
    policy = CtxChecker::Policy.new(required_components: { power: %w[PS1 PS2 PS3] })
    results = assess(:power, rows, policy: policy)
    expect(results.map(&:status)).to eq(%i[pass fail fail fail])
    expect(results.last.reason).to eq(:required_component_missing)
    expect(assess(:power, [], status: :partial, policy: policy).map(&:status)).to all(eq(:unknown))
  end

  it "does not turn a missing fan or contradictory presence into a healthy component" do
    expect(assess(:environment, [ { component: "fan 1", kind: :fan, status: :unknown } ]).first.status).to eq(:unknown)
    expect(assess(:environment, [ { component: "fan 1", kind: :fan, status: :failed } ], status: :partial).first.status).to eq(:fail)
    expect(assess(:power, [ { component: "PS1", kind: :power_supply, status: :ok, present: false } ]).first.status).to eq(:unknown)
    over_capacity = { component: "PS1", kind: :power_supply, status: :ok, present: true, watts: 500, capacity_watts: 100 }
    expect(assess(:power, [ over_capacity ]).map(&:status)).to eq(%i[fail unknown])
  end

  it "compares explicit clock zones at the command timestamp and reports skew separately from sync" do
    row = { component: "system", time: "2026-10-16T11:00:00+08:00" }
    expect(assess(:clock, [ row ]).first.status).to eq(:pass)
    policy = CtxChecker::Policy.new(max_clock_skew_seconds: 30)
    results = assess(:clock, [ row ], policy: policy, evidence: [ { observed_at: "2026-10-16T03:01:00Z" } ])
    expect(results.first.to_h).to include(status: :fail, actual: { time: row[:time], skew_seconds: 60.0 })
    expect(assess(:clock, [ row.merge(time: nil, synchronized: false) ]).map(&:status)).to eq(%i[fail unknown])
  end

  it "requires system NTP synchronization and preserves stratum, leap and signed offset faults" do
    row = { component: "system", synchronized: true, stratum: 2, leap: 0, offset_ms: -120 }
    expect(assess(:ntp, [ row ]).map(&:status)).to eq(%i[pass fail])
    policy = CtxChecker::Policy.new(max_ntp_offset_ms: 200)
    expect(assess(:ntp, [ row ], policy: policy).map(&:status)).to eq(%i[pass pass])
    [ { stratum: 16 }, { leap: 3 } ].each do |variant|
      results = assess(:ntp, [ row.merge(variant) ])
      expect(results.first.status).to eq(:fail)
      expect(results.map(&:reason)).to include(:ntp_state_inconsistent)
    end
    expect(assess(:ntp, [ row.merge(component: "peer 192.0.2.2") ]).map(&:status)).to eq(%i[not_applicable unknown])
    expect(assess(:ntp, [ row.merge(synchronized: nil, offset_ms: nil) ]).first.status).to eq(:unknown)
    expect(assess(:ntp, [ row.merge(stratum: 0, offset_ms: nil) ]).map(&:status)).to eq(%i[unknown unknown])
  end

  it "requires explicit clear alarm evidence and keeps active severity" do
    row = { component: "chassis", alarm_id: "summary", active: false, count: 0 }
    expect(assess(:alarms, [ row ]).first.status).to eq(:pass)
    expect(assess(:alarms, []).first.status).to eq(:unknown)
    expect(assess(:alarms, [ row.merge(active: true, count: 1, severity: :critical) ]).first.severity).to eq(:critical)
    expect(assess(:alarms, [ row.merge(count: 1) ]).first.status).to eq(:unknown)
    expect(assess(:alarms, [ row.merge(active: true, count: 1, severity: :info) ]).first.status).to eq(:not_applicable)
    expect(assess(:alarms, [ row ], status: :partial).first.status).to eq(:unknown)
  end

  it "separates a failed NTP peer attempt from current system synchronization" do
    peer = { component: "peer/unspecified/192.0.2.2", peer: "192.0.2.2", last_sync_status: :failed }
    results = assess(:ntp, [ { component: "system", synchronized: nil }, peer ], status: :partial)
    expect(results.map(&:reason)).to eq(%i[ntp_synchronization ntp_last_sync_failed])
    expect(results.map(&:status)).to eq(%i[unknown fail])
    expect(results.last.severity).to eq(:warning)
    results = assess(:ntp, [ { component: "system", synchronized: true, stratum: 2 }, peer ])
    expect(results.map(&:status)).to eq(%i[pass fail])
    expect(assess(:ntp, [ peer.merge(last_sync_status: :succeeded) ]).map(&:status)).to eq(%i[not_applicable unknown])
  end

  it "reports cumulative device errors separately from policy and informational counters" do
    row = { component: "dataplane", metric: "flow_error", category: :error, value: 12 }
    expect(assess(:device_counters, [ row ]).first.to_h).to include(status: :unknown, reason: :cumulative_errors, actual: 12)
    expect(assess(:device_counters, [ row.merge(value: 0) ]).first.status).to eq(:pass)
    expect(assess(:device_counters, [ row.merge(category: :informational) ]).first.status).to eq(:not_applicable)
    expect(assess(:device_counters, [ row.merge(category: :policy) ]).first.status).to eq(:not_applicable)
    expect(assess(:device_counters, [ row.merge(category: :unknown, value: 0) ]).first.status).to eq(:unknown)
  end

  it "calculates device deltas and rates only with matching epochs and policy thresholds" do
    row = { component: "dataplane", metric: "acl_drop", category: :policy, value: 10, discontinuity: "boot-1/clear-1" }
    previous = snapshot(:device_counters, [ row ], time: sample_time - 60)
    policy = CtxChecker::Policy.new(device_counter_limits: { "acl_drop" => 2 })
    result = assess(:device_counters, [ row.merge(value: 13) ], policy: policy, previous: previous).first
    expect(result.to_h).to include(status: :fail, actual: { cumulative: 13, delta: 3, seconds: 60.0, per_second: 0.05 })
    [ { discontinuity: nil }, { discontinuity: "boot-2" }, { value: 1 } ].each do |variant|
      expect(assess(:device_counters, [ row.merge(variant) ], policy: policy, previous: previous).first.status).to eq(:unknown)
    end
    expect(assess(:device_counters, [ row ], policy: policy, previous: previous, status: :partial).first.status).to eq(:unknown)
  end

  it "keeps required but unrequested dimensions unknown" do
    policy = CtxChecker::Policy.new(required_dimensions: %i[cpu memory alarms])
    report = CtxChecker::Evaluator.new(policy: policy).call(snapshot(:interfaces, []))
    expect(report.findings.select { |row| %i[cpu memory alarms].include?(row.dimension) }.map(&:status)).to all(eq(:unknown))
  end
end
