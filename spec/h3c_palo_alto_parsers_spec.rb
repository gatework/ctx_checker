# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"

RSpec.describe "H3C and PAN-OS runtime parsers" do
  def fixture(platform, name)
    File.read(File.expand_path("fixtures/ctx_checker/#{platform}/#{name}.txt", __dir__))
  end

  def parse(platform, dimension, text = fixture(platform, dimension), complete: true)
    options = platform == :h3c && dimension == :counters ? { command: "display interface" } : {}
    CtxChecker::RuntimeParser.new(platform: platform).parse(dimension, text, complete: complete, **options)
  end

  it "normalizes H3C physical and logical interfaces without conflating administrative down" do
    result = parse(:h3c, :interfaces)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:kind] }).to eq(%i[physical physical aggregate svi loopback tunnel subinterface])
    expect(result.records[1]).to include(admin_status: :down, oper_status: :down, protocol_status: :down)
    expect(result.records.last).to include(parent: "GigabitEthernet1/0/1")
  end

  it "reserves H3C interface details for CRC and unavailable discards, with directional errors collected separately" do
    result = parse(:h3c, :counters, fixture(:h3c, :interfaces))
    expect(result.status).to eq(:partial)
    rows = result.records.select { |row| row[:interface] == "GigabitEthernet1/0/1" }
    expect(rows).to include(include(metric: :crc_errors, value: 5), include(metric: :in_discards, value: nil))
    expect(rows).not_to include(include(metric: :in_errors), include(metric: :out_errors))
    expect(rows.map { |row| row[:discontinuity] }).to all(be_nil)
  end

  it "removes duplicate H3C interface identities and does not ignore unfamiliar blocks" do
    text = fixture(:h3c, :interfaces) + "GigabitEthernet1/0/1\nCurrent state: DOWN\nLine protocol state: DOWN\n"
    result = parse(:h3c, :interfaces, text)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(name: "GigabitEthernet1/0/1"))
    expect(parse(:h3c, :interfaces, fixture(:h3c, :interfaces) + "unfamiliar data\n").status).to eq(:partial)
  end

  it "does not extract integer suffixes from negative or fractional H3C counters" do
    %w[-0 +0 1.0].each do |value|
      text = fixture(:h3c, :interfaces).sub("5 CRC", "#{value} CRC")
      expect(parse(:h3c, :counters, text).records).to include(include(interface: "GigabitEthernet1/0/1", metric: :crc_errors, value: nil))
    end
  end

  it "does not select the first of conflicting H3C interface state fields" do
    [ "GigabitEthernet1/0/1\nCurrent state: UP\nCurrent state: DOWN\nLine protocol state: UP\n",
      "GigabitEthernet1/0/1 current state: UP\nCurrent state: DOWN\nLine protocol state: UP\n",
      "GigabitEthernet1/0/1\nCurrent state: UP\nLine protocol state: UP\nLine protocol state: DOWN\n" ].each do |text|
      result = parse(:h3c, :interfaces, text)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :duplicate_interface_state))
      expect(result.records.first.values_at(:oper_status, :protocol_status)).to include(:unknown)
    end
  end

  it "keeps selected and unselected H3C members within each local group" do
    result = parse(:h3c, :aggregation)
    expect(result).to be_complete
    expect(result.records.size).to eq(3)
    expect(result.records.first).to include(group: "Bridge-Aggregation10", member: "GigabitEthernet1/0/1", member_status: :active)
    expect(result.records.last).to include(group: "Route-Aggregation20", member: "Ten-GigabitEthernet1/0/3", member_status: :unselected)
    expect(parse(:h3c, :aggregation, fixture(:h3c, :aggregation).sub("GE1/0/1 S", "GE1/0/1 ?")).status).to eq(:partial)
  end

  it "parses H3C optical thresholds and lanes while keeping N/A distinct from zero" do
    result = parse(:h3c, :optics)
    expect(result).to be_complete
    expect(result.records.first).to include(interface: "Ten-GigabitEthernet1/0/1", metric: :rx_power, value: -12.0,
      high_alarm: 2.0, low_alarm: -10.0, high_warning: 1.0, low_warning: -8.0)
    expect(result.records[1]).to include(metric: :tx_power, high_alarm: 3.0, low_alarm: -8.0)
    expect(result.records[4]).to include(interface: "HundredGigE1/0/2", lane: 2, metric: :rx_power, value: nil)
  end

  it "keeps H3C missing or duplicate optical measurements unresolved" do
    text = fixture(:h3c, :optics).sub("    30 3.30 5.00 -12.00 -2.00\n", "")
    expect(parse(:h3c, :optics, text).status).to eq(:partial)
    text = fixture(:h3c, :optics).sub("    1 6.00 -1.00 -2.00\n", "    1 6.00 -1.00 -2.00\n" * 2)
    result = parse(:h3c, :optics, text)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(interface: "HundredGigE1/0/2", lane: 1))
    expect(parse(:h3c, :optics, fixture(:h3c, :optics) + "unfamiliar diagnostic field\n").status).to eq(:partial)
  end

  it "retains oversized H3C optical values and thresholds as unavailable measurements" do
    { "-12.00" => :value, "-10.00" => :low_alarm }.each do |source, field|
      result = parse(:h3c, :optics, fixture(:h3c, :optics).sub(source, "9" * 400))
      expect(result.status).to eq(:partial)
      expect(result.records.first[field]).to be_nil
      expect(result.issues).to include(include(code: :invalid_optics_measurement))
    end
  end

  it "retains H3C BGP shutdown and zero-prefix established states with an explicit public AF" do
    result = parse(:h3c, :bgp)
    expect(result).to be_complete
    expect(result.records.first).to include(vrf: "default", afi_safi: "ipv4_unicast", state: :established, received_prefixes: 0)
    expect(result.records.last[:state]).to eq(:shutdown)
    expect(parse(:h3c, :bgp, fixture(:h3c, :bgp).sub("peers: 2", "peers: 3")).status).to eq(:partial)
  end

  it "distinguishes explicit zero H3C BGP peers from a header-only or malformed table" do
    header = "Peer AS MsgRcvd MsgSent OutQ PrefRcv Up/Down State\n"
    expect(parse(:h3c, :bgp, "Total number of peers: 0\n" + header)).to be_complete
    expect(parse(:h3c, :bgp, header).status).to eq(:failed)
    expect(parse(:h3c, :bgp, fixture(:h3c, :bgp) + "192.0.2.3 corrupted\n").status).to eq(:partial)
  end

  it "retains OSPF process and interface identity without guessing DR Other adjacency topology" do
    result = parse(:h3c, :ospf)
    expect(result).to be_complete
    expect(result.records[1]).to include(state: :two_way, neighbor_role: :drother, network_type: :unknown, local_role: :unknown)
    expect(result.records.last).to include(process_id: "20", interface: "Vlan-interface20", state: :exstart)
    expect(parse(:h3c, :ospf, fixture(:h3c, :ospf).sub("Full/DR", "Unexpected/DR")).status).to eq(:partial)
  end

  it "keeps PAN physical operating state separate from unknown administrative and logical states" do
    result = parse(:palo_alto, :interfaces)
    expect(result).to be_complete
    expect(result.records.first).to include(oper_status: :up, admin_status: :unknown)
    expect(result.records[1]).to include(oper_status: :down)
    expect(result.records).to include(include(name: "ethernet1/1.20", parent: "ethernet1/1", oper_status: :unknown),
      include(name: "tunnel.1", kind: :tunnel), include(name: "loopback.1", kind: :loopback))
  end

  it "detects truncated PAN interface inventory using section totals" do
    text = fixture(:palo_alto, :interfaces).sub("hardware interfaces: 3", "hardware interfaces: 4")
    expect(parse(:palo_alto, :interfaces, text).status).to eq(:partial)
    expect(parse(:palo_alto, :interfaces, text + "ethernet1/9 malformed\n").status).to eq(:partial)
  end

  it "discards ambiguous PAN interface states rather than retaining the last duplicate" do
    text = fixture(:palo_alto, :interfaces).sub("aggregation groups:", "ethernet1/1 16 unknown/unknown/down 00:00:00:00:00:01\naggregation groups:")
    result = parse(:palo_alto, :interfaces, text)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(name: "ethernet1/1"))
  end

  it "maps PAN CPU error counters without treating them as CRC or adding two layers" do
    result = parse(:palo_alto, :counters)
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(interface: "ethernet1/1", metric: :in_errors, value: 7, unit: :packets, scope: :cpu),
      include(interface: "ethernet1/1", metric: :in_discards, value: 2, unit: :packets, scope: :cpu),
      include(interface: "ethernet1/1", metric: :crc_errors, value: nil),
      include(interface: "tunnel.1", metric: :in_errors, value: 2, unit: :packets, scope: :logical),
      include(interface: "management", metric: :out_errors, value: 2),
      include(interface: "management", metric: :out_discards, value: 4, unit: :packets, scope: :logical))
    expect(result.issues).to include(include(code: :missing_counter_metrics))
    expect(result.records.map { |row| row[:discontinuity] }).to all(be_nil)
  end

  it "does not accept malformed or duplicate PAN counters as zero" do
    text = fixture(:palo_alto, :counters).sub("receive errors 7", "receive errors invalid")
    result = parse(:palo_alto, :counters, text)
    expect(result.records).to include(include(interface: "ethernet1/1", metric: :in_errors, value: nil))
    expect(result.issues).to include(include(code: :unrecognized_counter_field))
    text = fixture(:palo_alto, :counters).sub("receive errors 7", "receive errors 7\nreceive errors 8")
    expect(parse(:palo_alto, :counters, text).records).not_to include(include(interface: "ethernet1/1", metric: :in_errors))
  end

  it "retains PAN LACP selection failures despite an otherwise active member" do
    result = parse(:palo_alto, :aggregation)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:member_status] }).to eq(%i[active unselected])
    expect(parse(:palo_alto, :aggregation, fixture(:palo_alto, :aggregation).sub("Tx_Rx Selected", "Attached Selected")).records.first[:member_status]).to eq(:unknown)
  end

  it "does not silently ignore a later aggregation group with missing members" do
    { h3c: "Aggregate Interface: Bridge-Aggregation99\n", palo_alto: "AE group: ae99\n" }.each do |platform, tail|
      result = parse(platform, :aggregation, fixture(platform, :aggregation) + tail)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :aggregation_members_missing))
    end
  end

  it "converts PAN mW to dBm and leaves thresholds absent rather than inventing a healthy range" do
    result = parse(:palo_alto, :optics)
    expect(result).to be_complete
    expect(result.records.first[:value]).to be_within(0.0001).of(-3.0103)
    expect(result.records[1][:value]).to be_within(0.0001).of(-6.0206)
    expect(result.records[2][:value]).to be_nil
    expect(result.records.map { |row| row[:low_alarm] }).to all(be_nil)
    zero = parse(:palo_alto, :optics, fixture(:palo_alto, :optics).sub("0.25 mW", "0.00 mW"))
    expect(zero.status).to eq(:partial)
    expect(zero.records[1][:value]).to be_nil
  end

  it "does not let oversized PAN optical power become nonfinite normalized observations" do
    result = parse(:palo_alto, :optics, fixture(:palo_alto, :optics).sub("0.50 mW", "#{'9' * 400} mW"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:value]).to be_nil
    expect(result.issues).to include(include(code: :invalid_optics_measurement))
  end

  it "retains PAN BGP virtual router, address families and IPv6 socket identity" do
    result = parse(:palo_alto, :bgp)
    expect(result).to be_complete
    expect(result.records.size).to eq(3)
    expect(result.records.first).to include(vrf: "default", afi_safi: "ipv4_unicast", peer: "192.0.2.1", received_prefixes: 0)
    expect(result.records.last).to include(vrf: "blue", afi_safi: "ipv6_unicast", peer: "2001:db8::2", state: :active)
  end

  it "keeps malformed PAN BGP fields or unfamiliar AFs partial" do
    expect(parse(:palo_alto, :bgp, fixture(:palo_alto, :bgp).sub("Remote AS: 65001", "Remote AS: unknown")).status).to eq(:partial)
    expect(parse(:palo_alto, :bgp, fixture(:palo_alto, :bgp).sub("bgpAfiIpv4 / unicast", "l2vpn evpn")).status).to eq(:partial)
    expect(parse(:palo_alto, :bgp, fixture(:palo_alto, :bgp).sub("Peer status: Established", "Peer status: Unknown")).status).to eq(:partial)
  end

  it "rejects out-of-range PAN ASNs and address-family suffixes" do
    [ 0, 4_294_967_296 ].each do |number|
      result = parse(:palo_alto, :bgp, fixture(:palo_alto, :bgp).sub("Remote AS: 65001", "Remote AS: #{number}"))
      expect(result.status).to eq(:partial)
      expect(result.records.first[:remote_as]).to be_nil
    end
    result = parse(:palo_alto, :bgp, fixture(:palo_alto, :bgp).sub("bgpAfiIpv4 / unicast", "bgpAfiIpv4 / unicast-other"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:afi_safi]).to be_nil
  end

  it "canonicalizes PAN IPv6 peers before detecting duplicate scoped identities" do
    text = fixture(:palo_alto, :bgp).sub("[2001:db8::2]", "[2001:0db8:0:0:0:0:0:2]")
    expect(parse(:palo_alto, :bgp, text).records.last[:peer]).to eq("2001:db8::2")
    duplicate = fixture(:palo_alto, :bgp).split("Peer: backup").last
    result = parse(:palo_alto, :bgp, text + "\nPeer: duplicate#{duplicate}")
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(vrf: "blue", peer: "2001:db8::2"))
  end

  it "retains PAN OSPF neighbor identity without inventing local interface and network type" do
    result = parse(:palo_alto, :ospf)
    expect(result).to be_complete
    expect(result.records.first).to include(vrf: "default", router_id: "192.0.2.2", neighbor_address: "192.0.2.1",
      state: :full, interface: nil, network_type: :unknown)
    expect(parse(:palo_alto, :ospf, fixture(:palo_alto, :ospf).sub("status: full", "status: new-state")).status).to eq(:partial)
    expect(parse(:palo_alto, :ospf, "Unknown device warning\n" + fixture(:palo_alto, :ospf)).status).to eq(:partial)
  end

  it "canonicalizes PAN OSPF neighbor addresses before detecting duplicate observations" do
    text = fixture(:palo_alto, :ospf).sub("neighbor address: 192.0.2.1", "neighbor address: 2001:0db8:0:0:0:0:0:1")
    expect(parse(:palo_alto, :ospf, text).records.first[:neighbor_address]).to eq("2001:db8::1")
    result = parse(:palo_alto, :ospf, text + text.sub("2001:0db8:0:0:0:0:0:1", "2001:db8::1"))
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
  end

  [ :h3c, :palo_alto ].each do |platform|
    it "keeps CLI failures, pagination, empty and unconfirmed output explicit for #{platform}" do
      CtxChecker::RuntimeParser.new(platform: platform).profile.commands.each_key do |dimension|
        expect(parse(platform, dimension, "Invalid command\n").status).to eq(:unsupported)
        expect(parse(platform, dimension, "Error: permission failure\n").status).to eq(:failed)
        expect(parse(platform, dimension, "").status).to eq(:failed)
      end
      expect(parse(platform, :interfaces, fixture(platform, :interfaces), complete: false).status).to eq(:partial)
      expect(parse(platform, :interfaces, fixture(platform, :interfaces) + "--More--\n").status).to eq(:partial)
    end
  end
end
