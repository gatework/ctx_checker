# frozen_string_literal: true

require_relative "spec_helper"
require "net/connector"
require "ctx_checker"

RSpec.describe "Runtime query coverage and explicit measurement requirements" do
  let(:bgp_scope) { { vrf: "default", afi_safi: "ipv4_unicast" } }
  let(:bgp_peer) { bgp_scope.merge(peer: "192.0.2.9") }
  let(:h3c_empty) { "Total number of peers: 0\nPeer AS MsgRcvd MsgSent OutQ PrefRcv Up/Down State\n" }
  let(:optic) do
    { interface: "Ethernet1/1", lane: 0, metric: :rx_power, value: -3.0, unit: :dbm,
      low_alarm: -18.0, high_alarm: 3.5, present: true, dom_supported: true }
  end

  def parse(platform, name, text, complete: true)
    CtxChecker::RuntimeParser.new(platform: platform).parse(name, text, complete: complete)
  end

  def evaluate(observation, policy:, interfaces: nil)
    observations = { observation.name => observation }
    observations[:interfaces] = interfaces if interfaces
    sample = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "h3c" },
      observed_at: Time.utc(2026, 10, 16), observations: observations)
    CtxChecker::Evaluator.new(policy: policy).call(sample)
  end

  def absent_peer(observation, peer: bgp_peer)
    evaluate(observation, policy: CtxChecker::Policy.new(expected_bgp: [ peer ])).findings.find { |row| row.reason == :expected_peer_missing }
  end

  it "retains explicit empty H3C BGP scope so the last required peer disappearing is a fault" do
    observation = parse(:h3c, :bgp, h3c_empty)
    expect(observation).to be_complete
    expect(observation.records).to be_empty
    expect(observation.covered_scopes).to eq([ bgp_scope ])
    expect(absent_peer(observation).status).to eq(:fail)
    expect(absent_peer(observation, peer: bgp_peer.merge(vrf: "blue")).status).to eq(:unknown)
    expect(absent_peer(observation, peer: bgp_peer.merge(afi_safi: "ipv6_unicast")).status).to eq(:unknown)
  end

  it "does not promote truncation, pagination, malformed totals or a bare header to complete coverage" do
    variants = [ h3c_empty.sub("peers: 0", "peers: 1"), h3c_empty + "--More--\n", h3c_empty.lines.last,
      h3c_empty.sub("peers: 0", "peers: 0 unknown"), "Total number of peers: 1\n" + h3c_empty ]
    variants.each do |body|
      observation = parse(:h3c, :bgp, body)
      expect(observation.covered_scopes).to be_empty
      expect(absent_peer(observation).status).to eq(:unknown)
    end
    observation = parse(:h3c, :bgp, h3c_empty, complete: false)
    expect(observation.covered_scopes).to be_empty
    expect(absent_peer(observation).status).to eq(:unknown)
  end

  it "preserves multiple empty Cisco VRF and address-family scopes independently" do
    body = <<~TEXT
      BGP summary information for VRF default, address family IPv4 Unicast
      BGP table version is 0, IPv4 Unicast config peers 0, capable peers 0
      BGP summary information for VRF blue, address family IPv6 Unicast
      BGP table version is 0, IPv6 Unicast config peers 0, capable peers 0
    TEXT
    observation = parse(:cisco_nxos, :bgp, body)
    expect(observation.covered_scopes).to eq([ bgp_scope, { vrf: "blue", afi_safi: "ipv6_unicast" } ])
    expect(absent_peer(observation).status).to eq(:fail)
    expect(absent_peer(observation, peer: bgp_peer.merge(vrf: "blue")).status).to eq(:unknown)
    ios = parse(:cisco_ios, :bgp, "For address family: IPv4 Unicast\nNo BGP neighbors\n")
    expect(ios.covered_scopes).to eq([ bgp_scope ])
    expect(absent_peer(ios).status).to eq(:fail)
  end

  it "covers all interfaces only within an explicitly enumerated OSPF process" do
    expected = { vrf: "blue", process_id: "TENANT", interface: "Ethernet1/1", router_id: "192.0.2.9" }
    policy = CtxChecker::Policy.new(expected_ospf: [ expected, expected.merge(process_id: "OTHER") ])
    observation = parse(:cisco_nxos, :ospf, "OSPF Process ID TENANT VRF blue\nTotal number of neighbors: 0\n")
    expect(observation.covered_scopes).to eq([ { vrf: "blue", process_id: "TENANT" } ])
    missing = evaluate(observation, policy: policy).findings.select { |row| row.reason == :expected_peer_missing }
    expect(missing.map(&:status)).to eq(%i[fail unknown])
    ios = parse(:cisco_ios, :ospf, "Process ID: 1\nNo OSPF neighbors\n")
    expect(ios.covered_scopes).to eq([ { vrf: "default", process_id: "1" } ])
    unscoped = parse(:cisco_ios, :ospf, "No OSPF neighbors\n")
    expect(unscoped.covered_scopes).to be_empty
  end

  it "carries scope proof through collection and source merging without upgrading failed sibling commands" do
    command = CtxChecker::RuntimeParser.new(platform: :h3c).profile.command(:bgp)
    response = command_receipt(h3c_empty, command: command)
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ command ]).and_return(response)
    sample = CtxChecker::Collector.new.collect_session(target: { host: "192.0.2.1", platform: "h3c" }, session: session, dimensions: [ :bgp ])
    observed = sample.observation(:bgp)
    expect(observed.covered_scopes).to eq([ bgp_scope ])
    failed = CtxChecker::Observation.new(name: :bgp, status: :failed,
      issues: [ { code: :command_error } ], evidence: [ { command: "display bgp vpnv4 all peer", status: :failed } ])
    merged = CtxChecker::ObservationMerger.call(:bgp, [ observed, failed ], commands: [ command, "display bgp vpnv4 all peer" ])
    expect(merged.status).to eq(:partial)
    expect(absent_peer(merged).status).to eq(:fail)
    expect(absent_peer(merged, peer: bgp_peer.merge(vrf: "blue")).status).to eq(:unknown)
    expect(evaluate(merged, policy: CtxChecker::Policy.new(expected_bgp: [ bgp_peer ]))).not_to be_complete
    expect(CtxChecker::Observation.new(**merged.to_h).covered_scopes).to eq([ bgp_scope ])
  end

  it "validates and isolates immutable scope identities while preserving legacy observations" do
    scopes = [ { vrf: "default".dup, afi_safi: "ipv4_unicast" } ]
    observed = CtxChecker::Observation.new(name: :bgp, status: :complete, covered_scopes: scopes)
    scopes.first[:vrf].replace("changed")
    expect(observed.covered_scopes).to eq([ bgp_scope ])
    expect(observed.covered_scopes.first).to be_frozen
    invalid = [ [ {} ], [ { vrf: "default" } ], [ bgp_scope, bgp_scope.dup ], [ bgp_scope.merge(command: "unsafe") ], [ bgp_scope.merge(vrf: "bad\n") ] ]
    invalid.each do |value|
      expect { CtxChecker::Observation.new(name: :bgp, status: :complete, covered_scopes: value) }.to raise_error(ArgumentError)
    end
    expect { CtxChecker::Observation.new(name: :bgp, status: :failed, covered_scopes: [ bgp_scope ]) }.to raise_error(ArgumentError)
    expect { CtxChecker::Observation.new(name: :interfaces, status: :complete, covered_scopes: [ bgp_scope ]) }.to raise_error(ArgumentError)
    expect(absent_peer(CtxChecker::Observation.new(name: :bgp, status: :complete)).status).to eq(:unknown)
    legacy = CtxChecker::Observation.new(name: :counters, status: :complete)
    expect(legacy.to_h.keys).to eq(%i[name status records issues evidence])
  end

  it "does not mistake conflicting peer records for a confirmed absence while retaining other scopes" do
    other_scope = bgp_scope.merge(vrf: "blue")
    sources = %i[established active].each_with_index.map do |state, index|
      CtxChecker::Observation.new(name: :bgp, status: :complete, records: [ bgp_peer.merge(state: state) ],
        covered_scopes: [ bgp_scope, other_scope ], evidence: [ { command: "read peers #{index}" } ])
    end
    merged = CtxChecker::ObservationMerger.call(:bgp, sources, commands: [ "read peers 0", "read peers 1" ])
    expect(merged.records).to be_empty
    expect(merged.covered_scopes).to eq([ other_scope ])
    expect(absent_peer(merged).status).to eq(:unknown)
    expect(absent_peer(merged, peer: bgp_peer.merge(vrf: "blue")).status).to eq(:fail)
  end

  it "retains scoped parser result value semantics and profile compatibility" do
    result = CtxChecker::Parsers::ScopedResult.new(status: :complete, covered_scopes: [ bgp_scope ])
    other = result.with(covered_scopes: [ bgp_scope.merge(vrf: "blue") ])
    expect(result).to be_a(CtxParser::Result)
    expect(result).not_to eq(other)
    expect([ result, other, result.with ].uniq.size).to eq(2)
    expect(result.deconstruct_keys([ :covered_scopes ])).to eq(covered_scopes: [ bgp_scope ])
    expect(result.to_h { |key, value| [ key.to_s, value ] }).to include("covered_scopes" => [ bgp_scope ])
    profile = CtxChecker::RuntimeParser.new(platform: :h3c).profile
    expect(profile.parse(:bgp, h3c_empty, complete: true).covered_scopes).to eq([ bgp_scope ])
  end

  it "keeps threshold overrides optional and makes missing required optical measurements explicit" do
    identity = { interface: "Ethernet1/2", lane: 0, metric: :rx_power }
    observation = CtxChecker::Observation.new(name: :optics, status: :complete, records: [ optic ])
    thresholds = [ identity.merge(low_alarm: -18.0, high_alarm: 3.5) ]
    expect(evaluate(observation, policy: CtxChecker::Policy.new(optical_thresholds: thresholds))).to be_healthy
    policy = CtxChecker::Policy.new(required_optics: [ identity ], optical_thresholds: thresholds)
    report = evaluate(observation, policy: policy)
    expect(report).not_to be_healthy
    expect(report.findings).to include(have_attributes(status: :fail, reason: :required_optics_missing, entity: identity))
    %i[partial failed unsupported not_requested].each do |status|
      missing = CtxChecker::Observation.new(name: :optics, status: status)
      expect(evaluate(missing, policy: policy).findings).to include(have_attributes(status: :unknown, reason: :required_optics_missing))
    end
  end

  it "does not exempt required optics on an administratively down interface or certify ambiguous lanes" do
    identity = optic.slice(:interface, :lane, :metric)
    policy = CtxChecker::Policy.new(required_optics: [ identity ])
    interfaces = CtxChecker::Observation.new(name: :interfaces, status: :complete,
      records: [ { name: optic[:interface], admin_status: :down, oper_status: :down } ])
    optical = CtxChecker::Observation.new(name: :optics, status: :complete, records: [ optic.merge(value: -30) ])
    expect(evaluate(optical, policy: policy, interfaces: interfaces).findings).to include(have_attributes(status: :fail, reason: :optical_threshold))
    unnumbered = CtxChecker::Observation.new(name: :optics, status: :complete, records: [ optic.merge(lane: nil) ])
    expect(evaluate(unnumbered, policy: policy).findings).to include(have_attributes(status: :unknown, reason: :required_optics_missing))
    copper = CtxChecker::Observation.new(name: :optics, status: :complete, records: [ identity.merge(applicable: false) ])
    expect(evaluate(copper, policy: policy).findings).to include(have_attributes(status: :unknown, reason: :required_optics_inapplicable))
    expect(evaluate(CtxChecker::Observation.new(name: :optics, status: :complete, records: [ optic ]), policy: policy)).to be_healthy
  end

  it "requires complete unique optical target identities without accepting thresholds as targets" do
    identity = optic.slice(:interface, :lane, :metric)
    [ [ identity.except(:lane) ], [ identity.merge(metric: :temperature) ], [ identity, identity.dup ],
      [ identity.merge(interface: "") ], [ identity.merge(value: 0) ] ].each do |values|
      expect { CtxChecker::Policy.new(required_optics: values) }.to raise_error(ArgumentError)
    end
    source = [ identity.dup ]
    policy = CtxChecker::Policy.new(required_optics: source)
    source.first[:interface] = "changed"
    expect(policy.required_optics).to eq([ identity ])
    expect(policy).to be_required_dimension(:optics)
  end
end
