# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/cisco_ios/profile"
require "ctx_checker/cisco_nxos/profile"
require "ctx_checker/observation"

RSpec.describe "Cisco runtime parsers" do
  def fixture(platform, name)
    File.read(File.expand_path("fixtures/ctx_checker/#{platform}/#{name}.txt", __dir__))
  end

  def profile(platform = :cisco_ios)
    platform == :cisco_ios ? CtxChecker::CiscoIos::Profile.new : CtxChecker::CiscoNxos::Profile.new
  end

  def observation(name, result)
    CtxChecker::Observation.new(name: name, **result.to_h)
  end

  it "parses physical, aggregate, SVI, loopback, tunnel and subinterfaces in one IOS command" do
    results = profile.parse_many(%i[interfaces counters], fixture(:cisco_ios, :interfaces), complete: true)
    interfaces = observation(:interfaces, results[:interfaces])
    expect(interfaces).to be_complete
    expect(interfaces.records.map { |row| row[:kind] }).to eq(%i[physical physical aggregate svi loopback tunnel subinterface])
    expect(interfaces.records[1]).to include(admin_status: :down, oper_status: :down)
    expect(interfaces.records.last).to include(parent: "GigabitEthernet1/0/1")
    counters = observation(:counters, results[:counters])
    expect(counters).to be_complete
    expect(counters.records.select { |row| row[:interface] == "GigabitEthernet1/0/2" }).to include(
      include(metric: :in_errors, value: 2), include(metric: :crc_errors, value: 2), include(metric: :out_errors, value: 3))
    expect(counters.records.map { |row| row[:discontinuity] }).to all(be_nil)
  end

  it "reads NX-OS administrative state independently and does not add CRC to input errors" do
    results = profile(:cisco_nxos).parse_many(%i[interfaces counters], fixture(:cisco_nxos, :interface), complete: true)
    expect(observation(:interfaces, results[:interfaces])).to be_complete
    expect(results[:interfaces].records[1]).to include(admin_status: :down, oper_status: :down)
    expect(results[:interfaces].records.first).to include(protocol_status: :unknown)
    counters = observation(:counters, results[:counters])
    expect(counters).to be_complete
    metrics = counters.records.select { |row| row[:interface] == "Ethernet1/1" }.to_h { |row| [ row[:metric], row[:value] ] }
    expect(metrics).to eq(in_errors: 2, out_errors: 4, crc_errors: 2, in_discards: 3, out_discards: 5)
  end

  it "keeps counter coverage partial for missing or malformed labelled values" do
    text = fixture(:cisco_ios, :interfaces).sub("0 input errors, 0 CRC", "unknown input errors, unknown CRC")
    result = profile.parse(:counters, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :counter_fields_missing))
    expect(profile.parse(:interfaces, text, complete: true)).to be_complete
  end

  it "preserves explicit IOS queue drops without treating missing metrics or negative tokens as zero" do
    text = <<~TEXT
      GigabitEthernet1/0/1 is up, line protocol is up
        Input queue: 0/2000/8/0 (size/max/drops/flushes); Total output drops: 9
        0 input errors, 0 CRC
        0 output errors
    TEXT
    result = profile.parse(:counters, text, complete: true)
    expect(observation(:counters, result)).to be_complete
    expect(result.records).to include(include(metric: :in_discards, value: 8, unit: :packets, scope: :queue),
      include(metric: :out_discards, value: 9, unit: :unknown, scope: :queue))

    malformed = text.sub("0 input errors", "-0 input errors").sub("0 CRC", "-1 CRC")
    result = profile.parse(:counters, malformed, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(metric: :in_errors), include(metric: :crc_errors))
    expect(result.issues).to include(include(code: :invalid_counter_value, metric: :in_errors))
    %w[1,000 1/0 1.0 +0].each do |value|
      result = profile.parse(:counters, text.sub("0 input errors", "#{value} input errors"), complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records).not_to include(include(metric: :in_errors))
    end

    result = profile.parse(:counters, "GigabitEthernet1/0/1 is up, line protocol is up\n0 input errors\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :counter_fields_missing, metrics: %i[out_errors crc_errors]))
  end

  it "rejects malformed optional discards and stops assigning counters after an unknown interface header" do
    text = <<~TEXT
      GigabitEthernet1/0/1 is up, line protocol is up
        0 input errors, 0 CRC, unavailable input discards
        0 output errors
      GigabitEthernet1/0/2 is broken-state
        27 output discards
    TEXT
    result = profile.parse(:counters, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :invalid_counter_value, metric: :in_discards))
    expect(result.records).not_to include(include(metric: :out_discards, value: 27))
  end

  it "rejects repeated metric labels on one line instead of retaining the first zero" do
    text = "GigabitEthernet1/0/1 is up, line protocol is up\n0 input errors, 0 CRC, 9 CRC\n0 output errors\n"
    result = profile.parse(:counters, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(metric: :crc_errors))
    expect(result.issues).to include(include(code: :duplicate_identity))
  end

  it "does not turn interface descriptions into errors, CRC or drops on either Cisco platform" do
    %i[cisco_ios cisco_nxos].each do |platform|
      file = platform == :cisco_ios ? :interfaces : :interface
      text = fixture(platform, file).sub(/\n/, "\n  Description: 98 input errors, 99 CRC; Total output drops: 97\n")
      result = profile(platform).parse(:counters, text, complete: true)

      expect(result).to be_complete
      expect(result.records).to include(include(metric: :crc_errors, value: platform == :cisco_ios ? 0 : 2))
      expect(result.records.map { |row| row[:value] }).not_to include(97, 98, 99)
      expect(result.issues).not_to include(include(code: :duplicate_identity))
    end
  end

  it "does not accept one recognized interface followed by unknown state syntax" do
    text = fixture(:cisco_ios, :interfaces) + "GigabitEthernet1/0/9 is unrecognized\n"
    expect(profile.parse(:interfaces, text, complete: true).status).to eq(:partial)
    duplicated = fixture(:cisco_ios, :interfaces) + "GigabitEthernet1/0/1 is down, line protocol is down\n"
    result = profile.parse(:interfaces, duplicated, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(name: "GigabitEthernet1/0/1"))
  end

  it "retains bundle parent, active, standby, suspended and down member states" do
    ios = <<~TEXT
      Flags: D - down P - bundled in port-channel
      Group Port-channel Protocol Ports
      1 Po1(SU) LACP Gi1/0/1(P) Gi1/0/2(H)
      2 Po2(SD) LACP Gi1/0/3(D) Gi1/0/4(s)
      Number of channel-groups in use: 2
    TEXT
    result = profile.parse(:aggregation, ios, complete: true)
    expect(observation(:aggregation, result)).to be_complete
    expect(result.records.map { |row| row[:member_status] }).to eq(%i[active standby down suspended])
    expect(result.records.last).to include(group: "Port-channel2", oper_status: :down)
    nxos = ios.sub("Group Port-channel Protocol Ports", "Group Port- Type Protocol Member Ports")
      .gsub("LACP Gi", "Eth LACP Gi")
    expect(profile(:cisco_nxos).parse(:aggregation, nxos, complete: true)).to be_complete
  end

  it "keeps unsupported members and explicit empty aggregation distinct" do
    text = "Group Port-channel Protocol Ports\n1 Po1(SU) LACP Gi1/0/1(P) Gi1/0/2(?)\n"
    expect(profile.parse(:aggregation, text, complete: true).status).to eq(:partial)
    empty = profile.parse(:aggregation, "Number of channel-groups in use: 0\nNumber of aggregators: 0\n", complete: true)
    expect(empty).to be_complete
    expect(empty.records).to be_empty
    no_members = profile.parse(:aggregation, "Group Port-channel Protocol Ports\n1 Po1(SD) LACP --\n", complete: true)
    expect(no_members).to be_complete
    expect(observation(:aggregation, no_members).records.first).to include(group: "Port-channel1", member: nil)
  end

  it "rejects duplicate aggregation parents and contradictory parent flags" do
    text = "Group Port-channel Protocol Ports\n1 Po1(SU) LACP Gi1/0/1(P)\n1 Po1(SD) LACP Gi1/0/2(D)\n"
    result = profile.parse(:aggregation, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :duplicate_aggregation_group))
    result = profile.parse(:aggregation, text.lines.first + "1 Po1(SUD) LACP Gi1/0/1(P)\n", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.first[:oper_status]).to eq(:unknown)
  end

  it "uses IOS DOM column order and explicit optical alarm markers" do
    result = profile.parse(:optics, fixture(:cisco_ios, :optics), complete: true)
    expect(observation(:optics, result)).to be_complete
    expect(result.records.last).to include(interface: "GigabitEthernet1/0/1", metric: :rx_power,
      value: -12.0, high_alarm: 2.0, high_warning: 1.0, low_warning: -6.0, low_alarm: -8.0, alarm: :low_alarm)
  end

  it "preserves per-lane NX-OS power, no-DOM and absent transceivers" do
    result = profile(:cisco_nxos).parse(:optics, fixture(:cisco_nxos, :optics), complete: true)
    expect(observation(:optics, result)).to be_complete
    expect(result.records.size).to eq(8)
    expect(result.records[1]).to include(interface: "Ethernet1/1", lane: 1, metric: :rx_power,
      value: -12.0, high_alarm: 3.0, low_alarm: -9.0, high_warning: 2.0, low_warning: -7.0)
    expect(result.records[4]).to include(interface: "Ethernet1/2", value: nil, present: true, dom_supported: false)
    expect(result.records[6]).to include(interface: "Ethernet1/3", value: nil, present: false)
  end

  it "retains missing optical measurements and cannot mistake N/A for zero" do
    text = fixture(:cisco_nxos, :optics).sub("-1.10 dBm", "N/A dBm")
    result = profile(:cisco_nxos).parse(:optics, text, complete: true)
    expect(result.records[2][:value]).to be_nil
    truncated = text.lines.reject { |line| line.include?("-1.20 dBm") }.join
    result = profile(:cisco_nxos).parse(:optics, truncated, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :optical_measurement_missing, lane: 2, metric: :rx_power))
  end

  it "supports IOS DOM lanes, calibration parentheses and unavailable current readings" do
    text = fixture(:cisco_ios, :optics).gsub("Port     (dBm)", "Port Lane (dBm)")
      .sub("Gi1/0/1  -2.0", "Gi1/0/1  1 -2.0 ( -1.9 )")
      .sub("Gi1/0/1  -12.0 --", "Gi1/0/1  1 N/A")
    result = profile.parse(:optics, text, complete: true)
    expect(result).to be_complete
    expect(result.records.first).to include(lane: 1, value: -2.0)
    expect(result.records.last[:value]).to be_nil
  end

  it "requires both power metrics for every IOS optical lane" do
    text = <<~TEXT
      Transmit Power Threshold Threshold Threshold Threshold
      Port Lane (dBm) (dBm) (dBm) (dBm) (dBm)
      Te1/0/1 1 -2.0 2.0 1.0 -6.0 -8.0
      Te1/0/1 2 -2.0 2.0 1.0 -6.0 -8.0
      Receive Power Threshold Threshold Threshold Threshold
      Port Lane (dBm) (dBm) (dBm) (dBm) (dBm)
      Te1/0/1 1 -2.0 2.0 1.0 -6.0 -8.0
    TEXT
    result = profile.parse(:optics, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :optical_measurement_missing, lane: 2, metric: :rx_power))
    duplicated = text + "Te1/0/1 1 -9.0 2.0 1.0 -6.0 -8.0\n"
    result = profile.parse(:optics, duplicated, complete: true)
    expect(result.records).not_to include(include(lane: 1, metric: :rx_power))
    expect(result.issues).to include(include(code: :duplicate_identity))
  end

  it "keeps malformed NX-OS alarm markers and missing thresholds inconclusive" do
    text = fixture(:cisco_nxos, :optics).sub("-12.00 dBm --", "-12.00 dBm +-")
    result = profile(:cisco_nxos).parse(:optics, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :unparsed_optical_measurement))
    text = fixture(:cisco_nxos, :optics).sub("3.00 dBm", "N/A dBm")
    result = profile(:cisco_nxos).parse(:optics, text, complete: true)
    expect(observation(:optics, result).records.first).to include(high_alarm: nil, high_warning: 2.0, low_warning: -7.0, low_alarm: -9.0)
  end

  it "retains contradictory NX-OS module presence and DOM declarations" do
    base = <<~TEXT
      Ethernet1/1
      transceiver is present
      Measurement High Low High Low
      Tx Power -2.0 dBm 3.0 dBm -9.0 dBm 2.0 dBm -7.0 dBm
      Rx Power -2.0 dBm 3.0 dBm -9.0 dBm 2.0 dBm -7.0 dBm
    TEXT
    missing = base.sub("transceiver is present", "transceiver is not present\ntransceiver is present")
    result = profile(:cisco_nxos).parse(:optics, missing, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :contradictory_transceiver_presence))
    unsupported = base.sub("transceiver is present", "transceiver is present\nDOM is not supported")
    result = profile(:cisco_nxos).parse(:optics, unsupported, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :contradictory_dom_support))
  end

  it "retains finite observations when a measurement or threshold overflows Float" do
    giant = "9" * 400
    { cisco_ios: [ "-2.0", "2.0" ], cisco_nxos: [ "-1.10", "3.00" ] }.each do |platform, values|
      values.each do |value|
        text = fixture(platform, :optics).sub(value, giant)
        result = profile(platform).parse(:optics, text, complete: true)
        expect(result.status).to eq(:partial)
        expect(result.issues).to include(include(code: :invalid_optical_value))
        expect { observation(:optics, result) }.not_to raise_error
        expect(result.records.flat_map(&:values).grep(Float)).to all(be_finite)
      end
    end
  end

  it "normalizes BGP state, ASN, AF and VRF without treating zero routes as Idle" do
    text = <<~TEXT
      BGP summary information for VRF default, address family IPv4 Unicast
      BGP router identifier 192.0.2.10, local AS number 65000
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      192.0.2.1 4 65001 12 15 1 0 0 00:10:00 0
      192.0.2.2 4 1.10 0 0 0 0 0 never Idle (Admin)
      BGP summary information for VRF blue, address family IPv4 Unicast
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      192.0.2.1 4 65001 1 1 1 0 0 00:00:01 Active
    TEXT
    result = profile(:cisco_nxos).parse(:bgp, text, complete: true)
    expect(observation(:bgp, result)).to be_complete
    expect(result.records.first).to include(state: :established, received_prefixes: 0, afi_safi: "ipv4_unicast")
    expect(result.records[1]).to include(state: :shutdown, remote_as: 65_546)
    expect(result.records.last).to include(vrf: "blue", state: :active)
    expect(profile(:cisco_nxos).parse(:bgp, text + "192.0.2.3 broken row\n", complete: true).status).to eq(:partial)
  end

  it "does not declare header-only BGP healthy and preserves explicit empty output" do
    header = "Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd\n"
    expect(profile.parse(:bgp, header, complete: true)).not_to be_complete
    expect(profile.parse(:bgp, "No BGP neighbors found\n", complete: true)).to be_complete
    text = header + "192.0.2.1 4 65001 0 0 0 0 0 never Idle\n" * 2
    result = profile.parse(:bgp, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
  end

  it "keeps BGP empty, truncated and wrapped peers within their own VRF and AF" do
    text = <<~TEXT
      BGP summary information for VRF empty, address family IPv4 Unicast
      No BGP neighbors found
      BGP summary information for VRF blue, address family IPv6 Unicast
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      2001:db8::1
        4 65001 0 0 0 0 0 00:01:00 0
    TEXT
    result = profile(:cisco_nxos).parse(:bgp, text, complete: true)
    expect(observation(:bgp, result)).to be_complete
    expect(result.records.first).to include(vrf: "blue", afi_safi: "ipv6_unicast", peer_address: "2001:db8::1", received_prefixes: 0)

    truncated = text + "2001:db8::2\nBGP summary information for VRF red, address family IPv6 Unicast\n4 65002 0 0 0 0 0 never Idle\n"
    result = profile(:cisco_nxos).parse(:bgp, truncated, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(peer_address: "2001:db8::2"))
    expect(result.issues).to include(include(code: :truncated_peer))
  end

  it "does not reuse an earlier VRF table header for later BGP rows" do
    text = <<~TEXT
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      192.0.2.1 4 65001 0 0 0 0 0 00:01:00 0
      BGP summary information for VRF blue, address family IPv4 Unicast
      192.0.2.1 4 65001 0 0 0 0 0 00:01:00 0
    TEXT
    result = profile(:cisco_nxos).parse(:bgp, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :missing_neighbor_header))
  end

  it "does not let an earlier healthy BGP section hide an empty trailing scope" do
    text = <<~TEXT
      BGP summary information for VRF default, address family IPv4 Unicast
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      192.0.2.1 4 65001 0 0 0 0 0 00:01:00 0
      BGP summary information for VRF blue, address family IPv4 Unicast
    TEXT
    result = profile(:cisco_nxos).parse(:bgp, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :neighbor_count_unavailable))
  end

  it "combines separate VRF and address-family declarations into one BGP scope" do
    text = <<~TEXT
      BGP VRF blue, state Active
      For address family: IPv6 Unicast
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      2001:db8::1 4 65001 0 0 0 0 0 00:01:00 0
    TEXT
    result = profile.parse(:bgp, text, complete: true)
    expect(result).to be_complete
    expect(result.records.first).to include(vrf: "blue", afi_safi: "ipv6_unicast")
  end

  it "keeps OSPF topology unknown and validates totals within each process" do
    text = <<~TEXT
      OSPF Process ID 10 VRF default
      Neighbor ID Pri State Up Time Address Interface
      192.0.2.1 1 FULL/DR 00:20:00 192.0.2.2 Eth1/1
      Total number of neighbors: 1
      OSPF Process ID 20 VRF blue
      Neighbor ID Pri State Up Time Address Interface
      192.0.2.1 1 2WAY/DROTHER 00:20:00 192.0.2.2 Eth1/1
      Total number of neighbors: 1
    TEXT
    result = profile(:cisco_nxos).parse(:ospf, text, complete: true)
    expect(observation(:ospf, result)).to be_complete
    expect(result.records.last).to include(process_id: "20", vrf: "blue", state: :two_way,
      network_type: :unknown, local_role: :unknown, neighbor_role: :drother)
    ios = "Neighbor ID Pri State Dead Time Address Interface\n192.0.2.1 1 FULL/ - 00:00:34 192.0.2.2 Gi1/0/1\n"
    expect(profile.parse(:ospf, ios, complete: true).records.first).to include(process_id: nil)
    expect(profile(:cisco_nxos).parse(:ospf, text.sub("neighbors: 1", "neighbors: 2"), complete: true).status).to eq(:partial)
  end

  it "supports NX-OS totals before rows and explicit empty OSPF processes" do
    text = <<~TEXT
      OSPF Process ID 1 VRF default
      Total number of neighbors: 1
      Neighbor ID Pri State Up Time Address Interface
      192.0.2.1 1 FULL/DR 00:20:00 192.0.2.2 Eth1/1
      OSPF Process ID 2 VRF blue
      Total number of neighbors: 0
      Neighbor ID Pri State Up Time Address Interface
    TEXT
    result = profile(:cisco_nxos).parse(:ospf, text, complete: true)
    expect(observation(:ospf, result)).to be_complete
    expect(result.records.size).to eq(1)
    expect(profile(:cisco_nxos).parse(:ospf, text.sub("neighbors: 1", "neighbors: 2"), complete: true).status).to eq(:partial)
    without_total = text.sub("Total number of neighbors: 0\n", "")
    expect(profile(:cisco_nxos).parse(:ospf, without_total, complete: true).status).to eq(:partial)
  end

  it "retains OSPF corruption and conflicting neighbor identities as partial evidence" do
    text = <<~TEXT
      OSPF Process ID 1 VRF default
      Total number of neighbors: 3
      Neighbor ID Pri State Up Time Address Interface
      192.0.2.1 1 FULL/DR 00:20:00 192.0.2.2 Eth1/1
      192.0.2.1 1 DOWN/DR 00:20:00 192.0.2.2 Eth1/1
      192.0.2.3 1 BROKEN/DR 00:20:00 192.0.2.4 Eth1/2
    TEXT
    result = profile(:cisco_nxos).parse(:ospf, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :duplicate_identity), include(code: :unparsed_row), include(code: :count_mismatch))
  end

  it "does not let an earlier full adjacency hide an empty trailing OSPF scope" do
    text = <<~TEXT
      OSPF Process ID 1 VRF default
      Neighbor ID Pri State Up Time Address Interface
      192.0.2.1 1 FULL/DR 00:20:00 192.0.2.2 Eth1/1
      OSPF Process ID 2 VRF blue
    TEXT
    result = profile(:cisco_nxos).parse(:ospf, text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :neighbor_count_unavailable))
  end

  it "rejects CLI errors, pagination and unconfirmed capture completeness across all dimensions" do
    profile.commands.keys.each do |name|
      result = profile.parse(name, "% Invalid input detected at '^' marker.\n", complete: true)
      expect(result.status).to eq(:unsupported)
      expect(result.records).to be_empty
    end
    text = fixture(:cisco_ios, :interfaces)
    expect(profile.parse(:interfaces, text, complete: false).status).to eq(:partial)
    expect(profile.parse(:interfaces, text + "--More--\n", complete: true).status).to eq(:partial)
  end
end
