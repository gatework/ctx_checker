# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Protocol scope matching" do
  def missing_peers(name, scopes:, expected:, records: [])
    observation = CtxChecker::Observation.new(name: name, status: :complete, records: records, covered_scopes: scopes)
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "cisco_nxos" },
      observed_at: Time.utc(2026, 10, 18), observations: { name => observation })
    policy = CtxChecker::Policy.new(**{ name == :bgp ? :expected_bgp : :expected_ospf => expected })
    CtxChecker::Evaluator.new(policy: policy).call(snapshot).findings.select { |finding| finding.reason == :expected_peer_missing }
  end

  def merge_peers(name, records:, scopes:, first_scopes: scopes)
    observations = [ first_scopes, scopes ].each_with_index.map do |covered, index|
      CtxChecker::Observation.new(name: name, status: :complete, records: records, covered_scopes: covered,
        evidence: [ { command: "read peers #{index}" } ])
    end
    CtxChecker::ObservationMerger.call(name, observations, commands: [ "read peers 0", "read peers 1" ])
  end

  it "matches BGP coverage by field identity regardless of hash order" do
    peer = { vrf: "blue", afi_safi: "ipv4_unicast", peer: "192.0.2.9" }
    findings = missing_peers(:bgp, scopes: [ { afi_safi: "ipv4_unicast", vrf: "blue" } ],
      expected: [ peer, peer.merge(vrf: "red"), peer.merge(afi_safi: "ipv6_unicast") ])

    expect(findings.map(&:status)).to eq(%i[fail unknown unknown])
    expect(findings.map(&:entity)).to eq([ peer, peer.merge(vrf: "red"), peer.merge(afi_safi: "ipv6_unicast") ])
  end

  it "limits OSPF interface coverage while honoring process-wide coverage" do
    peer = { vrf: "blue", process_id: "1", interface: "Ethernet1/1", router_id: "192.0.2.9" }
    findings = missing_peers(:ospf,
      scopes: [ { interface: "Ethernet1/1", process_id: "1", vrf: "blue" }, { process_id: "2", vrf: "blue" } ],
      expected: [ peer, peer.merge(interface: "Ethernet1/2"), peer.merge(process_id: "2", interface: "Ethernet1/2"), peer.merge(vrf: "red") ])

    expect(findings.map(&:status)).to eq(%i[fail unknown fail unknown])
  end

  it "keeps missing peers unknown when no source established coverage" do
    peer = { vrf: "blue", afi_safi: "ipv4_unicast", peer: "192.0.2.9" }
    expect(missing_peers(:bgp, scopes: [], expected: [ peer ]).map(&:status)).to eq([ :unknown ])
  end

  it "does not turn an incompletely scoped BGP record into confirmed absence" do
    peer = { vrf: "blue", afi_safi: "ipv4_unicast", peer: "192.0.2.9" }
    findings = missing_peers(:bgp, scopes: [ peer.slice(:afi_safi, :vrf) ], expected: [ peer, peer.merge(peer: "192.0.2.10") ],
      records: [ { peer: "192.0.2.9", afi_safi: "ipv4_unicast", state: :established } ])

    expect(findings.map(&:status)).to eq(%i[unknown fail])
  end

  it "invalidates BGP scopes matched by a conflicting record with an unknown VRF" do
    scopes = [ { afi_safi: "ipv4_unicast", vrf: "blue" }, { vrf: "red", afi_safi: "ipv4_unicast" },
      { vrf: "blue", afi_safi: "ipv6_unicast" } ]
    merged = merge_peers(:bgp, records: [ { peer: "192.0.2.9", afi_safi: "ipv4_unicast", state: :established } ],
      scopes: scopes, first_scopes: [])

    expect(merged.status).to eq(:partial)
    expect(merged.records).to be_empty
    expect(merged.covered_scopes).to eq([ { vrf: "blue", afi_safi: "ipv6_unicast" } ])
  end

  it "invalidates broad and interface-specific OSPF scopes for a conflicting unscoped interface" do
    scopes = [ { vrf: "blue", process_id: "1" }, { interface: "Ethernet1/1", process_id: "1", vrf: "blue" },
      { vrf: "blue", process_id: "1", interface: "Ethernet1/2" }, { vrf: "blue", process_id: "2" }, { vrf: "red", process_id: "1" } ]
    merged = merge_peers(:ospf, scopes: scopes,
      records: [ { vrf: "blue", process_id: "1", router_id: "192.0.2.9", state: :full } ])

    expect(merged.status).to eq(:partial)
    expect(merged.records).to be_empty
    expect(merged.covered_scopes).to eq([ { vrf: "blue", process_id: "2" }, { vrf: "red", process_id: "1" } ])
  end

  it "retains unrelated OSPF interfaces when a conflicting record has an explicit interface" do
    scopes = [ { process_id: "1", vrf: "blue" }, { vrf: "blue", interface: "Ethernet1/1", process_id: "1" },
      { process_id: "1", interface: "Ethernet1/2", vrf: "blue" } ]
    merged = merge_peers(:ospf, scopes: scopes,
      records: [ { vrf: "blue", process_id: "1", interface: "Ethernet1/1", router_id: "192.0.2.9", state: :full } ])

    expect(merged.covered_scopes).to eq([ { process_id: "1", interface: "Ethernet1/2", vrf: "blue" } ])
  end

  it "does not invent coverage when conflicting sources supplied none" do
    merged = merge_peers(:bgp, scopes: [], records: [ { peer: "192.0.2.9", state: :established } ])

    expect(merged.status).to eq(:partial)
    expect(merged.records).to be_empty
    expect(merged.covered_scopes).to be_empty
  end
end
