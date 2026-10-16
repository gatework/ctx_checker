# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/cisco_ios/profile"
require "ctx_checker/cisco_nxos/profile"

RSpec.describe "Catalyst 9500 live output layouts" do
  let(:profile) { CtxChecker::CiscoIos::Profile.new }

  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/cisco_ios/catalyst9500_#{name}.txt", __dir__))
  end

  it "preserves SVI Autostate headers and 25G counters without interpreting metadata as health" do
    results = profile.parse_many(%i[interfaces counters], fixture(:interfaces), complete: true)
    expect(results.values).to all(be_complete)
    expect(results[:interfaces].records.map { |row| row[:name] }).to eq(%w[Vlan7 TwentyFiveGigE1/0/1 GigabitEthernet0/0])
    expect(results[:counters].records).to include(include(interface: "TwentyFiveGigE1/0/1", metric: :crc_errors, value: 2))
    text = fixture(:interfaces).sub("Autostate Enabled", "Autostate FUTURE")
    expect(profile.parse(:interfaces, text, complete: true)).not_to be_complete
  end

  it "recognizes column dividers and maps aggregation and optical 25G names consistently" do
    text = "Group Port-channel Protocol Ports\n------+-------------+-----------+----------\n1 Po1(SU) LACP Twe1/0/1(P)\n"
    result = profile.parse(:aggregation, text, complete: true)
    expect(result).to be_complete
    expect(result.records.size).to eq(1)
    expect(result.records.first[:member]).to eq("TwentyFiveGigE1/0/1")
    result = profile.parse(:optics, fixture(:transceiver), complete: true)
    expect(result).to be_complete
    expect(result.records.size).to eq(2)
    expect(result.records).to all(include(interface: "TwentyFiveGigE1/0/1", lane: nil))
    expect(profile.parse(:optics, fixture(:transceiver).sub("N/A   -1.0", "UNKNOWN   -1.0"), complete: true)).not_to be_complete
  end

  it "ignores BGP accounting preamble while still parsing and validating neighbors" do
    text = <<~TEXT
      BGP router identifier 192.0.2.1, local AS number 65001
      49/22 BGP path/bestpath attribute entries using 14504 bytes of memory
      1 BGP extended community entries using 60 bytes of memory
      91 received paths for inbound soft reconfiguration
      486 networks peaked at 09:50:33 Aug 27 2026 UTC (7w1d ago)
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      192.0.2.2 4 65002 10 10 1 0 0 1d02h 12
    TEXT
    result = profile.parse(:bgp, text, complete: true)
    expect(result).to be_complete
    expect(result.records.size).to eq(1)
    expect(result.records.first).to include(state: :established, received_prefixes: 12)
    expect(profile.parse(:bgp, text.sub("1d02h 12", "1d02h FUTURE"), complete: true)).not_to be_complete
  end

  it "accepts trace metadata but retains exact memory arithmetic validation" do
    text = "Tracekey : 1#abcdef123\nProcessor Pool Total: 1000 Used: 400 Free: 600\n"
    expect(profile.parse(:memory, text, complete: true)).to be_complete
    expect(profile.parse(:memory, text.sub("Free: 600", "Free: 601"), complete: true)).not_to be_complete
  end

  it "keeps switch-local power and fan identities and lets component failures override parent ok" do
    results = profile.parse_many(%i[temperature environment power], fixture(:environment), complete: true)
    expect(results.values).to all(be_complete)
    expect(results[:power].records.size).to eq(3)
    expect(results[:power].records).to include(include(component: "switch 1/power supply PS1", status: :failed, capacity_watts: 650.0))
    expect(results[:environment].records).to include(include(component: "switch 1/fan tray FM1", status: :failed))
    expect(results[:temperature].records.map { |row| row[:component] }).to eq([ "Switch2-R0/Temp: Outlet_A", "Switch1-R0/Temp: Outlet_A" ])
    invalid = fixture(:environment).sub("PS0     C9K-PWR-650WAC-R      AC    650 W", "PS0     C9K-PWR-650WAC-R      AC    unknown W")
    expect(profile.parse(:power, invalid, complete: true)).not_to be_complete
  end

  it "recognizes an explicit disabled NTP state with IOS diagnostic punctuation" do
    result = profile.parse(:ntp, "%NTP is not enabled.\n", complete: true)
    expect(result).to be_complete
    expect(result.records.size).to eq(1)
    expect(result.records.first[:synchronized]).to be(false)
    expect(profile.parse(:ntp, "%NTP is not enabled. extra\n", complete: true)).not_to be_complete
  end

  it "distinguishes explicit IP-stack drops, ignored options policy, and generated fragments" do
    text = <<~TEXT
      IP statistics:
      6 format errors, 7 checksum errors, 8 bad hop count
      0 unknown protocol, 0 other, 3 ignored
      5 fragmented, 10 fragments, 1 couldn't fragment
      2 invalid hole
      4 encapsulation failed, 0 no route, 9 unsupported-addr
      ICMP statistics:
    TEXT
    result = profile.parse(:device_counters, text, complete: true)
    expect(result).to be_complete
    expect(result.records).to include(include(metric: "invalid_hole", category: :error, value: 2),
      include(metric: "unsupported_address", category: :discard, value: 9), include(metric: "options_ignored", category: :policy, value: 3))
    expect(result.records).not_to include(include(value: 10))
    expect(profile.parse(:device_counters, text.sub("2 invalid hole", "unknown invalid hole"), complete: true)).not_to be_complete
  end

  it "keeps a successful transport with empty NX-OS aggregation output unresolved" do
    result = CtxChecker::CiscoNxos::Profile.new.parse(:aggregation, "", complete: true)
    expect(result.status).to eq(:failed)
    expect(result.issues).to include(include(code: :unrecognized_output))
  end

  it "recognizes NX-OS vPC annotations only when they agree with the aggregate operational state" do
    text = <<~TEXT
      port-channel30 is down (No operational members)
        vPC Status: Down, vPC number: 30 [packets forwarded via vPC peer-link]
      port-channel43 is up
        vPC Status: Up, vPC number: 43
    TEXT
    nxos = CtxChecker::CiscoNxos::Profile.new
    result = nxos.parse(:interfaces, text, complete: true)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:oper_status] }).to eq(%i[down up])
    expect(nxos.parse(:interfaces, text.sub("vPC Status: Up", "vPC Status: Down"), complete: true)).not_to be_complete
  end
end
