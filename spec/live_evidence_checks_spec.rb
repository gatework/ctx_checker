# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/evaluator"

RSpec.describe "Health checks over live device evidence" do
  def evaluate(name, records, status: :complete, interfaces: [], interface_status: :complete, policy: CtxChecker::Policy.new, issues: [])
    observations = {
      name => CtxChecker::Observation.new(name: name, status: status, records: records, issues: issues),
      interfaces: CtxChecker::Observation.new(name: :interfaces, status: interface_status, records: interfaces)
    }
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "h3c" }, observed_at: Time.utc(2026, 10, 16), observations: observations)
    CtxChecker::Evaluator.new(policy: policy).call(snapshot).findings.select { |finding| finding.dimension == name }
  end

  let(:copper) { { interface: "Ethernet1/1", metric: :rx_power, applicable: false, dom_supported: false } }
  let(:member) { { group: "Bridge-Aggregation100", member: "GigabitEthernet1/0/47", member_status: :active, oper_status: :unknown } }
  let(:parent) { { name: "Bridge-Aggregation100", kind: :aggregate, admin_status: :up, oper_status: :up, protocol_status: :up } }

  it "distinguishes confirmed copper optics inapplicability from absent transceivers" do
    result = evaluate(:optics, [ copper ]).first
    expect(result.to_h).to include(status: :not_applicable, reason: :optics_not_applicable)
    expect(evaluate(:optics, [ copper.except(:applicable).merge(present: false) ]).first.reason).to eq(:transceiver_absent)
  end

  it "does not exempt an incomplete or contradictory optical record" do
    expect(evaluate(:optics, [ copper ], status: :partial).first.status).to eq(:unknown)
    expect(evaluate(:optics, [ copper.merge(source_complete: false) ]).first.status).to eq(:unknown)
    expect(evaluate(:optics, [ copper.merge(present: true, alarm: :low_alarm) ]).first.status).to eq(:fail)
  end

  it "keeps complete copper evidence usable beside a failed sibling source" do
    result = evaluate(:optics, [ copper.merge(source_complete: true) ], status: :partial)
    expect(result.first.status).to eq(:not_applicable)
    expect(result.last.reason).to eq(:incomplete_evidence)
  end

  it "resolves selected H3C members with complete parent interface state" do
    expect(evaluate(:aggregation, [ member ], interfaces: [ parent ]).first.status).to eq(:pass)
    expect(evaluate(:aggregation, [ member ], interfaces: [ parent.merge(oper_status: :down) ]).first.status).to eq(:fail)
  end

  it "does not infer aggregate state from a partial or unrelated interface" do
    expect(evaluate(:aggregation, [ member ], interfaces: [ parent ], interface_status: :partial).first.status).to eq(:unknown)
    expect(evaluate(:aggregation, [ member ], interfaces: [ parent.merge(source_complete: false) ]).first.status).to eq(:unknown)
    expect(evaluate(:aggregation, [ member ], interfaces: [ parent.merge(name: "Bridge-Aggregation200") ]).first.status).to eq(:unknown)
  end

  it "uses the same complete aggregate state for minimum active capacity" do
    policy = CtxChecker::Policy.new(minimum_active_members: { "Bridge-Aggregation100" => 1 })
    results = evaluate(:aggregation, [ member ], interfaces: [ parent ], policy: policy)
    expect(results.find { |finding| finding.reason == :aggregation_capacity }.to_h).to include(status: :pass, actual: 1)
  end

  it "retains explicit member failure even when its parent interface is up" do
    result = evaluate(:aggregation, [ member.merge(member_status: :unselected) ], interfaces: [ parent ]).first
    expect(result.to_h).to include(status: :fail, reason: :aggregation_member_down)
  end

  it "retains a complete physical member down state despite a selected membership and up parent" do
    physical = { name: member[:member], kind: :physical, admin_status: :up, oper_status: :down }
    policy = CtxChecker::Policy.new(minimum_active_members: { member[:group] => 1 })
    [ member, member.merge(oper_status: :up) ].each do |row|
      results = evaluate(:aggregation, [ row ], interfaces: [ parent, physical ], policy: policy)
      expect(results.first.status).to eq(:fail)
      expect(results.first.actual[:oper_status]).to eq(:up)
      expect(results.find { |finding| finding.reason == :aggregation_capacity }.to_h).to include(status: :fail, actual: 0)
    end
  end

  it "describes explicit unconfigured routing separately from empty or rejected output" do
    result = evaluate(:ospf, [], status: :partial, issues: [ { code: :protocol_not_configured } ])
    expect(result.first.to_h).to include(status: :unknown, reason: :protocol_not_configured)
    expect(evaluate(:ospf, [], status: :failed).first.reason).to eq(:failed)
    disabled = evaluate(:ospf, [], status: :partial, issues: [ { code: :protocol_disabled } ])
    expect(disabled.first.to_h).to include(status: :unknown, reason: :protocol_disabled)
  end
end
