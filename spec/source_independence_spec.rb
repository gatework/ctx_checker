# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"
require "ctx_checker/observation_merger"

RSpec.describe CtxChecker::Evaluator, "source independence" do
  let(:target) { { host: "192.0.2.42", platform: "h3c" } }
  let(:sample_time) { Time.utc(2026, 10, 16, 12) }
  let(:counter_record) { { interface: "GigabitEthernet1/0/1", metric: :out_errors, value: 3, discontinuity: "verified-epoch" } }
  let(:optical_record) do
    { interface: "GigabitEthernet1/0/1", metric: :rx_power, value: 2, unit: :dbm,
      low_alarm: -20, high_alarm: 0, alarm: :high_alarm, source_complete: true }
  end

  def snapshot(observations, at: sample_time)
    CtxChecker::Snapshot.new(target: target, observed_at: at, observations: observations)
  end

  def counters(source_complete: nil, status: :partial)
    row = counter_record.dup
    row[:source_complete] = source_complete unless source_complete.nil?
    CtxChecker::Observation.new(name: :counters, status: status, records: [ row ],
      issues: status == :partial ? [ { code: :command_failed, command: "display counters inbound interface" } ] : [])
  end

  def dimension_findings(report, dimension)
    report.findings.select { |finding| finding.dimension == dimension }
  end

  it "passes a proven counter delta while retaining unknown coverage from a failed sibling source" do
    previous = snapshot({ counters: counters(source_complete: true) }, at: sample_time - 60)
    current = snapshot({ counters: counters(source_complete: true) })
    report = described_class.new.call(current, previous: previous)
    results = dimension_findings(report, :counters)
    expect(results).to include(have_attributes(status: :pass, reason: :counter_delta, actual: { delta: 0, seconds: 60.0 }))
    expect(results).to include(have_attributes(status: :unknown, reason: :incomplete_evidence))
    expect(report).not_to be_healthy
    expect(report).not_to be_complete
  end

  it "requires complete sources in both samples before passing a normal delta" do
    [ [ false, true ], [ true, false ] ].each do |prior_complete, current_complete|
      previous = snapshot({ counters: counters(source_complete: prior_complete) }, at: sample_time - 60)
      current = snapshot({ counters: counters(source_complete: current_complete) })
      results = dimension_findings(described_class.new.call(current, previous: previous), :counters)
      expect(results).to include(have_attributes(status: :unknown, reason: :counter_evidence_incomplete))
      expect(results.map(&:status)).not_to include(:pass)
    end
  end

  it "keeps legacy partial observations conservative when source metadata is absent" do
    previous = snapshot({ counters: counters }, at: sample_time - 60)
    results = dimension_findings(described_class.new.call(snapshot({ counters: counters }), previous: previous), :counters)
    expect(results).to include(have_attributes(status: :unknown, reason: :counter_evidence_incomplete))
    expect(results.map(&:status)).not_to include(:pass)
  end

  it "does not let complete observation status override explicitly incomplete source evidence" do
    observation = CtxChecker::Observation.new(name: :counters, status: :complete,
      records: [ counter_record.merge(value: 0, source_complete: false) ])
    results = dimension_findings(described_class.new.call(snapshot({ counters: observation })), :counters)
    expect(results.map(&:status)).not_to include(:pass)
    expect(results).to include(have_attributes(status: :unknown, reason: :incomplete_evidence))
  end

  it "quarantines cross-source identity conflicts and retains unknown coverage after merging" do
    records = [ { component: "cpu0", scope: "control", utilization: 10, source_complete: true },
      { component: "cpu1", scope: "control", utilization: 10, source_complete: true } ]
    first = CtxChecker::Observation.new(name: :cpu, status: :complete, records: records,
      evidence: [ { command: "show cpu first", status: :complete } ])
    second = CtxChecker::Observation.new(name: :cpu, status: :complete,
      records: [ records.first.merge(utilization: 99) ], evidence: [ { command: "show cpu second", status: :complete } ])
    merged = CtxChecker::ObservationMerger.call(:cpu, [ first, second ], commands: [ "show cpu first", "show cpu second" ])
    report = described_class.new.call(snapshot({ cpu: merged }))
    expect(merged.status).to eq(:partial)
    expect(merged.records.map { |row| row[:component] }).to eq([ "cpu1" ])
    expect(merged.issues).to include(include(code: :duplicate_identity))
    expect(dimension_findings(report, :cpu)).to include(have_attributes(status: :pass), have_attributes(status: :unknown))
    expect(report).not_to be_healthy
  end

  it "does not exempt an optical alarm using incomplete interface shutdown evidence" do
    interfaces = CtxChecker::Observation.new(name: :interfaces, status: :partial,
      records: [ { name: optical_record[:interface], admin_status: :down, source_complete: false } ])
    optics = CtxChecker::Observation.new(name: :optics, status: :complete, records: [ optical_record ])
    results = dimension_findings(described_class.new.call(snapshot({ interfaces: interfaces, optics: optics })), :optics)
    expect(results).to include(have_attributes(status: :fail, reason: :optical_alarm))
    expect(results.map(&:status)).not_to include(:not_applicable)
  end

  it "retains administrative optical exemptions when their interface source is complete" do
    interfaces = CtxChecker::Observation.new(name: :interfaces, status: :partial,
      records: [ { name: optical_record[:interface], admin_status: :down, source_complete: true } ],
      issues: [ { code: :command_failed } ])
    optics = CtxChecker::Observation.new(name: :optics, status: :complete, records: [ optical_record ])
    results = dimension_findings(described_class.new.call(snapshot({ interfaces: interfaces, optics: optics })), :optics)
    expect(results).to include(have_attributes(status: :not_applicable, reason: :administratively_down))
  end

  it "validates source metadata without coercing strings into booleans or statuses" do
    [ "true", 1, :complete ].each do |value|
      expect do
        CtxChecker::Observation.new(name: :counters, status: :partial, records: [ counter_record.merge(source_complete: value) ])
      end.to raise_error(ArgumentError)
    end
    [ "complete", :not_requested, :unknown, nil ].each do |value|
      expect do
        CtxChecker::Observation.new(name: :counters, status: :partial, evidence: [ { command: "display counters", status: value } ])
      end.to raise_error(ArgumentError)
    end
    %i[complete partial failed unsupported].each do |status|
      observation = CtxChecker::Observation.new(name: :counters, status: :partial, evidence: [ { command: "display counters", status: status } ])
      expect(observation.evidence.first[:status]).to eq(status)
    end
  end

  it "accepts exception class names while rejecting raw exception messages in metadata" do
    [ "secret token", "RuntimeError\nsecret", "", 42, :RuntimeError ].each do |value|
      expect do
        CtxChecker::Observation.new(name: :cpu, status: :failed, issues: [ { code: :parser_error, error_type: value } ])
      end.to raise_error(ArgumentError)
    end
    observation = CtxChecker::Observation.new(name: :cpu, status: :failed,
      issues: [ { code: :parser_error, error_type: "Net::Connector::Error" } ])
    expect(observation.issues.first[:error_type]).to eq("Net::Connector::Error")
  end

  it "enforces the same exception metadata contract for snapshot-level failures" do
    [ "private token", "IOError\nprivate", "", nil, :IOError ].each do |value|
      expect do
        CtxChecker::Snapshot.new(target: target, observed_at: sample_time, observations: {},
          issues: [ { code: :session_close_failed, stage: :close, error_type: value } ])
      end.to raise_error(ArgumentError)
    end
    snapshot = CtxChecker::Snapshot.new(target: target, observed_at: sample_time, observations: {},
      issues: [ { code: :session_close_failed, stage: :close, error_type: "IOError" } ])
    expect(snapshot.issues.first[:error_type]).to eq("IOError")
  end
end
