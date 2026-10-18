# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"

RSpec.describe "Aggregation capacity source evidence" do
  def evaluate(records, minimum:)
    observation = CtxChecker::Observation.new(name: :aggregation, status: :partial, records: records,
      issues: [ { code: :incomplete_command_set } ])
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "h3c" },
      observed_at: Time.utc(2026, 10, 18), observations: { aggregation: observation })
    policy = CtxChecker::Policy.new(minimum_active_members: { "Port-channel1" => minimum })
    CtxChecker::Evaluator.new(policy: policy).call(snapshot)
  end

  it "preserves a proven capacity lower bound while keeping incomplete coverage explicit" do
    active = { group: "Port-channel1", member: "Ethernet1/1", member_status: :active, oper_status: :up, source_complete: true }
    records = [ active, active.merge(member: "Ethernet1/2"), active.merge(member: "Ethernet1/3", source_complete: false) ]
    report = evaluate(records, minimum: 2)

    expect(report.findings).to include(have_attributes(reason: :aggregation_capacity, status: :pass, actual: 2))
    expect(report.findings).to include(have_attributes(reason: :incomplete_evidence, status: :unknown))
    expect(report).not_to be_healthy
    expect(report).not_to be_complete
    expect(evaluate(records, minimum: 3).findings).to include(have_attributes(reason: :aggregation_capacity, status: :unknown, actual: 2))
  end

  it "cannot prove sufficient capacity from absent or incomplete member evidence" do
    [ [], [ { group: "Port-channel1", member: "Ethernet1/1", member_status: :active, oper_status: :up, source_complete: false } ],
      [ { group: "Port-channel1", member: "Ethernet1/1", member_status: :active, oper_status: :up } ] ].each do |records|
      expect(evaluate(records, minimum: 1).findings).to include(have_attributes(reason: :aggregation_capacity, status: :unknown, actual: 0))
    end
  end
end
