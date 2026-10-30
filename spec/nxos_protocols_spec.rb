# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"

RSpec.describe "NX-OS protocol summary variants" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :cisco_nxos) }

  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/cisco_nxos/#{name}.txt", __dir__))
  end

  def parse(name, text, complete: true)
    parser.parse(name, text, complete: complete)
  end

  it "accepts documented NX-OS dampening and soft-reconfiguration statistics" do
    result = parse(:bgp, fixture(:bgp_summary))
    expect(result).to be_complete
    expect(result.records.map { |record| record.values_at(:vrf, :state, :received_prefixes) }).to eq([
      [ "default", :established, 3 ], [ "default", :established, 0 ], [ "blue", :active, nil ]
    ])
  end

  it "checks configured peer counts separately for each VRF" do
    result = parse(:bgp, fixture(:bgp_summary).lines.reject { |line| line.start_with?("192.0.2.2") }.join)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :count_mismatch, expected: 2, observed: 1))
    expect(result.records.last).to include(vrf: "blue", state: :active)
  end

  it "recognizes a validated zero-peer section without assuming a header is sufficient" do
    text = "BGP summary information for VRF empty, address family IPv4 Unicast\n" \
      "BGP table version is 0, IPv4 Unicast config peers 0, capable peers 0\n"
    expect(parse(:bgp, text)).to be_complete
    expect(parse(:bgp, text).records).to be_empty
    expect(parse(:bgp, text, complete: false)).not_to be_complete
    expect(parse(:bgp, text.lines.first)).not_to be_complete
  end

  it "does not equate capable peers with established neighbors" do
    text = fixture(:bgp_summary).lines.reject { |line| line.match?(/Dampening|received paths|identical/) }.join
    expect(parse(:bgp, text)).to be_complete
    expect(parse(:bgp, text).records.last[:state]).to eq(:active)
  end

  it "keeps peer totals and wrapped IPv6 neighbors scoped to their address family" do
    text = fixture(:bgp_summary) + <<~TEXT
      BGP summary information for VRF default, address family IPv6 Unicast
      BGP table version is 0, IPv6 Unicast config peers 1, capable peers 1
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      2001:db8:100:200::1
        4 65001 12 15 1 0 0 00:10:00 0
    TEXT
    expect(parse(:bgp, text)).to be_complete
    expect(parse(:bgp, text).records.last).to include(vrf: "default", afi_safi: "ipv6_unicast", peer_address: "2001:db8:100:200::1")
    expect(parse(:bgp, text.sub("IPv6 Unicast config peers 1", "IPv6 Unicast config peers 2")).status).to eq(:partial)
  end

  it "retains incapable peers as unknown and still accounts for their declared neighbor count" do
    text = fixture(:bgp_summary).sub("00:10:00 0", "00:10:00 0 (No Cap)")
    result = parse(:bgp, text)
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(peer_address: "192.0.2.2", vrf: "default", afi_safi: "ipv4_unicast",
      remote_as: 65002, state: :unknown, received_prefixes: nil))
    expect(result.issues).to include(include(code: :peer_capability_unavailable))
    expect(result.issues).not_to include(include(code: :count_mismatch), include(code: :unparsed_peer))
    expect(result.records.size).to eq(3)
  end

  it "does not apply NX-OS capability suffixes to IOS or accept unknown annotations" do
    text = "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n" \
      "192.0.2.2 4 65002 11 15 12 0 0 00:10:00 0 (No Cap)\n"
    ios = CtxChecker::RuntimeParser.new(platform: :cisco_ios).parse(:bgp, text, complete: true)
    expect(ios).not_to be_complete
    expect(ios.records).to be_empty
    expect(ios.issues).to include(include(code: :unparsed_peer))
    expect(parse(:bgp, text.sub("(No Cap)", "(Future Cap)")).records).to be_empty
  end

  it "rejects impossible, repeated, malformed and mismatched address-family counts" do
    base = fixture(:bgp_summary).lines.reject { |line| line.match?(/Dampening|received paths|identical/) }.join
    [ base.sub("capable peers 2", "capable peers 3"),
      base.sub("config peers 2", "config peers unavailable"),
      base.sub("IPv4 Unicast config peers 2", "IPv6 Unicast config peers 2"),
      base.sub("3 network entries", "BGP table version is 12, IPv4 Unicast config peers 2, capable peers 2\n3 network entries") ].each do |text|
      expect(parse(:bgp, text)).not_to be_complete
    end
  end

  it "does not accept a new unknown statistics syntax as an auxiliary line" do
    result = parse(:bgp, fixture(:bgp_summary).sub("0 dampened paths", "0 dampened paths warning: unknown"))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :unparsed_row))
  end

  it "does not associate rows after a malformed BGP scope with the previous VRF" do
    text = fixture(:bgp_summary).sub("VRF blue, address family IPv4 Unicast", "VRF blue, address family")
    result = parse(:bgp, text)
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(peer_address: "192.0.2.1", vrf: "default", state: :established))
    expect(result.records).not_to include(include(vrf: "default", state: :active))
  end

  it "keeps OSPF process, VRF, neighbor role and subinterface identities independent" do
    result = parse(:ospf, fixture(:ospf_neighbors))
    expect(result).to be_complete
    expect(result.records.first).to include(process_id: "UNDERLAY", vrf: "default", interface: "Ethernet1/29.29", neighbor_role: :unknown)
    expect(result.records.last).to include(process_id: "TENANT", vrf: "blue", state: :two_way, network_type: :unknown)
  end

  it "does not associate neighbors after a malformed OSPF scope with an earlier process" do
    [ "OSPF Process ID TENANT VRF", "OSPF Process ID" ].each do |scope|
      text = fixture(:ospf_neighbors).sub("OSPF Process ID TENANT VRF blue", scope)
      result = parse(:ospf, text)
      expect(result.status).to eq(:partial)
      expect(result.records).to include(include(process_id: "UNDERLAY", vrf: "default", router_id: "192.0.2.1", state: :full))
      expect(result.records.last).to include(process_id: nil, vrf: nil)
    end
  end

  it "accepts whitespace variations in explicit NX-OS process scope" do
    text = fixture(:ospf_neighbors).sub("OSPF Process ID UNDERLAY VRF default", "OSPF  Process ID  UNDERLAY  VRF  default")
    result = parse(:ospf, text)
    expect(result).to be_complete
    expect(result.records.first).to include(process_id: "UNDERLAY", vrf: "default")
  end

  it "rejects IPv6 and prefix values in an OSPFv2 neighbor table" do
    [ fixture(:ospf_neighbors).sub("192.0.2.2", "2001:db8::2"),
      fixture(:ospf_neighbors).sub("198.51.100.9", "2001:db8::9"),
      fixture(:ospf_neighbors).sub("198.51.100.9", "198.51.100.9/24") ].each do |text|
      result = parse(:ospf, text)
      expect(result.status).to eq(:partial)
      expect(result.records.size).to eq(2)
    end
  end

  it "keeps incomplete, unknown and contradictory OSPF sections inconclusive" do
    [ fixture(:ospf_neighbors).sub("Total number of neighbors: 2", "Total number of neighbors: 3"),
      fixture(:ospf_neighbors).sub("FULL/BDR", "FUTURE/BDR"),
      fixture(:ospf_neighbors) + "OSPF Process ID EMPTY VRF red\n" ].each do |text|
      expect(parse(:ospf, text).status).to eq(:partial)
    end
    expect(parse(:ospf, fixture(:ospf_neighbors), complete: false)).not_to be_complete
  end
end
