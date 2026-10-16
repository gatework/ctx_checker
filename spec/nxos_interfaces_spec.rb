# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"

# 合成回显保留文档规定的 NX-OS 布局，不作为实际设备证据。
RSpec.describe "NX-OS interface command variants" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :cisco_nxos) }

  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/cisco_nxos/#{name}.txt", __dir__))
  end

  def parse(name, text, complete: true)
    parser.parse(name, text, complete: complete)
  end

  it "accepts Nexus 7000 metadata and autostate SVI headers without losing counters" do
    results = parser.parse_many(%i[interfaces counters], fixture(:interface_n7000_83), complete: true)
    expect(results.values).to all(be_complete)
    expect(results[:interfaces].records).to include(
      include(name: "Ethernet10/25", parent: "Port-channel700", admin_status: :up),
      include(name: "Vlan63", kind: :svi, oper_status: :up, protocol_status: :up))
    expect(results[:counters].records.to_h { |row| [ row[:metric], row[:value] ] }).to eq(
      in_errors: 2, out_errors: 4, crc_errors: 2, in_discards: 3, out_discards: 5)
  end

  it "does not let an unknown suffix or state contaminate the previous interface" do
    text = fixture(:interface_n7000_83) + "Ethernet10/26 is up, new state format\n77 output error\n"
    results = parser.parse_many(%i[interfaces counters], text, complete: true)
    expect(results.values.map(&:status)).to eq(%i[partial partial])
    expect(results[:counters].records).not_to include(include(value: 77))
    expect(results[:interfaces].issues).to include(include(code: :unparsed_interface_header))
  end

  it "retains incomplete transport coverage despite recognized NX-OS syntax" do
    result = parse(:interfaces, fixture(:interface_n7000_83), complete: false)
    expect(result.status).to eq(:partial)
    expect(result.records.map { |row| row[:source_complete] }).to all(be(false))
  end

  it "reads administrative SVI shutdown before its protocol and autostate fields" do
    result = parse(:interfaces, "Vlan72 is down (Administratively down), line protocol is down, autostate enabled\n")
    expect(result).to be_complete
    expect(result.records.first).to include(name: "Vlan72", admin_status: :down, oper_status: :down, protocol_status: :down)
  end

  it "keeps new administrative state syntax inconclusive" do
    result = parse(:interfaces, "Ethernet1/7 is up\nadmin state is unknown-state\n")
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(admin_status: :unknown, source_complete: false)
  end

  it "parses wrapped FEX members with whitespace before their state flags" do
    result = parse(:aggregation, fixture(:aggregation_fex_7x))
    expect(result).to be_complete
    expect(result.records.size).to eq(7)
    expect(result.records).to include(
      include(group: "Port-channel24", member: "Ethernet105/1/29", member_status: :active),
      include(member: "Ethernet105/1/31", member_status: :down),
      include(member: "Ethernet105/1/32", member_status: :suspended),
      include(group: "Port-channel33", oper_status: :down, member: nil))
  end

  it "does not reparent members under a malformed aggregation group" do
    text = <<~TEXT
      Group Port- Type Protocol Member Ports
      24 Po24(SU) Eth LACP Eth105/1/27(P)
      25 Po25(SU) Eth NEW-PROTOCOL Eth105/1/28(P)
                       Eth105/1/29(P)
    TEXT
    result = parse(:aggregation, text)
    expect(result.status).to eq(:partial)
    expect(result.records.map { |row| row[:member] }).to eq([ "Ethernet105/1/27" ])
  end

  it "keeps invalid member tokens visible while preserving valid neighboring members" do
    result = parse(:aggregation, fixture(:aggregation_fex_7x).sub("Eth105/1/29 (P)", "Eth105/1/29 (?) garbage"))
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(member: "Ethernet105/1/29", member_status: :unknown))
    expect(result.issues).to include(include(code: :unparsed_member), include(code: :unknown_member_status))
  end

  it "preserves unitless N/A OLT power as unavailable measurements" do
    result = parse(:optics, fixture(:optics_olt_106))
    expect(result).to be_complete
    expect(result.records.size).to eq(2)
    expect(result.records).to all(include(value: nil, present: true, dom_supported: true, alarm: :unknown))
    expect(result.records.first).to include(high_alarm: 7.99, low_alarm: 2.99, high_warning: 6.99, low_warning: 3.99)
  end

  it "requires numeric optical readings to include their dBm unit" do
    result = parse(:optics, fixture(:optics_olt_106).sub("Tx Power      N/A", "Tx Power      5.0"))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :unparsed_optical_measurement))
  end

  it "reports unavailable OLT measurements as unknown health even after a complete parse" do
    observation = parse(:optics, fixture(:optics_olt_106))
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "cisco_nxos" },
      observed_at: "2026-10-16T01:00:00Z", observations: { optics: observation })
    report = CtxChecker::Evaluator.new.call(snapshot)
    expect(report).not_to be_healthy
    expect(report.findings.select { |finding| finding.dimension == :optics }.map(&:status)).to all(eq(:unknown))
  end

  it "requires an independent DOM header for every lane" do
    text = fixture(:optics).sub("Lane Number:2 Network Lane\n                Current              Alarms                  Warnings\n                Measurement     High        Low         High          Low", "Lane Number:2 Network Lane")
    result = parse(:optics, text)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :missing_optical_header))
  end

  it "never assigns an unknown lane to the prior valid lane" do
    text = fixture(:optics).sub("Lane Number:2", "Lane Number:unknown")
    result = parse(:optics, text)
    expect(result.status).to eq(:partial)
    lane_one = result.records.select { |row| row[:interface] == "Ethernet1/1" }
    expect(lane_one.size).to eq(2)
    expect(lane_one).to all(include(lane: 1))
    expect(result.issues).to include(include(code: :invalid_optical_lane))
    expect(result.issues).not_to include(include(code: :duplicate_identity))
  end
end
