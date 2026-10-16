# frozen_string_literal: true

require_relative "spec_helper"
require "json"
require "ctx_checker/evaluator"

RSpec.describe "CtxChecker domain contracts" do
  let(:target) { { host: "192.0.2.1", platform: "cisco_nxos" } }
  let(:record) { { name: "Ethernet1/1", kind: :physical, admin_status: :up, oper_status: :up, protocol_status: :up } }

  def row(name, records = [], status: :complete, **options)
    CtxChecker::Observation.new(name: name, status: status, records: records, **options)
  end

  it "deep copies records, identities and diagnostics without freezing caller data" do
    issues = [ { code: :unsupported_field, lines: [ 3 ] } ]
    record[:name] = record[:name].dup
    observation = row(:interfaces, [ record ], issues: issues)
    record[:name].replace("changed")
    issues.first[:lines] << 4
    expect(observation.records.first[:name]).to eq("Ethernet1/1")
    expect(observation.issues.first[:lines]).to eq([ 3 ])
    expect { observation.records.first[:name].replace("bad") }.to raise_error(FrozenError)
    expect(observation.records.first[:parent]).to be_nil
  end

  it "rejects missing identity, invalid types, nonfinite metrics and duplicate composite identities" do
    [ {}, record.merge(kind: :ethernet), record.merge(oper_status: "up"), record.merge(password: "secret") ].each do |invalid|
      expect { row(:interfaces, [ invalid ]) }.to raise_error(ArgumentError)
    end
    expect { row(:interfaces, [ record, record.dup ]) }.to raise_error(ArgumentError, /Duplicate/)
    expect { row(:counters, [ { interface: "Ethernet1/1", metric: :crc_errors, value: "0" } ]) }.to raise_error(ArgumentError)
    expect { row(:optics, [ { interface: "Ethernet1/1", metric: :rx_power, value: Float::NAN } ]) }.to raise_error(ArgumentError)
    expect { row(:optics, [ { interface: "Ethernet1/1", metric: :rx_power, value: Complex(1, 2) } ]) }.to raise_error(ArgumentError)
    expect { row(:interfaces, [ record ], status: :failed) }.to raise_error(ArgumentError)
  end

  it "keeps repeated peer addresses separate by context and OSPF neighbor address" do
    peer = { vrf: "default", afi_safi: "ipv4_unicast", peer: "192.0.2.2", state: :established }
    expect(row(:bgp, [ peer, peer.merge(vrf: "blue") ]).records.size).to eq(2)
    ospf = { vrf: "default", process_id: nil, interface: nil, router_id: "192.0.2.2", neighbor_address: "192.0.2.3" }
    expect(row(:ospf, [ ospf, ospf.merge(neighbor_address: "192.0.2.4") ]).records.size).to eq(2)
  end

  it "accepts optional counter provenance without changing legacy offline observations" do
    counter = { interface: "Ethernet1/1", metric: :crc_errors, value: 0 }
    expect(row(:counters, [ counter ]).records.first[:source_command]).to be_nil
    expect(row(:counters, [ counter.merge(source_command: nil) ]).records.first[:source_command]).to be_nil
    expect(row(:counters, [ counter.merge(source_command: "show interface") ]).records.first[:source_command]).to eq("show interface")
    [ "", "show interface\n", 1, :show_interface ].each do |source|
      expect { row(:counters, [ counter.merge(source_command: source) ]) }.to raise_error(ArgumentError)
    end
    expect { row(:interfaces, [ record.merge(source_command: "show interface") ]) }.to raise_error(ArgumentError)
  end

  it "normalizes sample time and retains unrequested dimensions" do
    snapshot = CtxChecker::Snapshot.new(target: target, observed_at: "2026-10-15T10:00:00+08:00", observations: { interfaces: row(:interfaces, [ record ]) })
    expect(snapshot.observed_at).to eq(Time.utc(2026, 10, 15, 2))
    expect(snapshot.observation(:bgp).status).to eq(:not_requested)
    expect(JSON.parse(JSON.generate(snapshot.to_h))["observed_at"]).to eq("2026-10-15T02:00:00.000000Z")
    expect { CtxChecker::Snapshot.new(target: target.merge(password: "secret"), observed_at: Time.now, observations: {}) }.to raise_error(ArgumentError)
    expect { CtxChecker::Snapshot.new(target: target.merge(host: "host\nforged"), observed_at: Time.now, observations: {}) }.to raise_error(ArgumentError)
    expect { CtxChecker::Snapshot.new(target: target, observed_at: "not-a-date", observations: {}) }.to raise_error(ArgumentError)
    expect { CtxChecker::Snapshot.new(target: target, observed_at: Time.now, observations: { bgp: row(:interfaces) }) }.to raise_error(ArgumentError)
  end

  it "captures immutable command acquisition times once and rejects untyped timestamps" do
    observation = row(:interfaces, [ record ], evidence: [ { observed_at: "2026-10-15T10:00:00+08:00" } ])
    expect(observation.observed_at).to eq(Time.utc(2026, 10, 15, 2))
    expect(observation.observed_at).to equal(observation.observed_at)
    expect(observation.observed_at).to be_frozen
    expect { row(:interfaces, [ record ], evidence: [ { observed_at: Time.now } ]) }.to raise_error(ArgumentError)
  end

  it "validates immutable policy expectations before any collection" do
    members = { "Port-channel1" => [ "Ethernet1/1" ] }
    policy = CtxChecker::Policy.new(required_members: members, minimum_active_members: { "Port-channel1" => 2 })
    members["Port-channel1"] << "Ethernet1/2"
    expect(policy.required_members["Port-channel1"]).to eq([ "Ethernet1/1" ])
    [ { required_interfaces: [ "" ] }, { minimum_active_members: { "Po1" => 0 } }, { counter_limits: { crc_errors: -1 } },
      { expected_bgp: [ { peer: "192.0.2.2" } ] }, { expected_ospf: [ { vrf: "default", process_id: nil, interface: "Eth1/1", router_id: "192.0.2.2" } ] } ].each do |invalid|
      expect { CtxChecker::Policy.new(**invalid) }.to raise_error(ArgumentError)
    end
  end

  it "requires unique optical policy identities and complete ordered threshold pairs" do
    thresholds = { interface: "Ethernet1/1", lane: 0, metric: :rx_power, low_alarm: -18.0, high_alarm: 3.5 }
    policy = CtxChecker::Policy.new(optical_thresholds: [ thresholds ])
    thresholds[:low_alarm] = -25
    expect(policy.optical_thresholds_for(interface: "Ethernet1/1", lane: 0, metric: :rx_power)[:low_alarm]).to eq(-18.0)
    expect(policy.optical_thresholds_for(interface: "Ethernet1/1", lane: 1, metric: :rx_power)).to be_nil
    invalid = [ [ thresholds, thresholds.dup ], [ thresholds.except(:high_alarm) ], [ thresholds.merge(low_warning: 4) ],
      [ thresholds.merge(high_alarm: Float::INFINITY) ], [ thresholds.merge(metric: :temperature) ], [ thresholds.merge(unit: :dbm) ] ]
    invalid.each { |values| expect { CtxChecker::Policy.new(optical_thresholds: values) }.to raise_error(ArgumentError) }
  end

  it "renders useful bounded measurements without terminal control characters" do
    sample = CtxChecker::Snapshot.new(target: target, observed_at: Time.now, observations: {})
    finding = CtxChecker::Finding.new(id: "optics.optical_threshold", dimension: :optics, status: :fail, reason: :optical_threshold,
      entity: { interface: "Ethernet1/1" }, actual: { value: -20, label: "\e[31m\n#{'x' * 700}" }, expected: { low_alarm: -18 })
    report = CtxChecker::Report.new(snapshot: sample, findings: [ finding ])
    expect(report.to_text).to include('actual={"value":-20', 'expected={"low_alarm":-18}')
    expect(report.to_text.lines.size).to eq(2)
    expect(report.to_text).not_to include("\e")
    expect(report.to_text.lines.last.length).to be < 700
    expect { CtxChecker::Finding.new(id: "unsafe\n", dimension: :optics, status: :fail, reason: :optical_threshold) }.to raise_error(ArgumentError)
    expect { CtxChecker::Finding.new(id: "optics.error", dimension: :optics, status: :fail, reason: :"unsafe\n") }.to raise_error(ArgumentError)
  end
end
