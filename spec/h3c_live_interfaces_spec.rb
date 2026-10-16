# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"

RSpec.describe "H3C S5130S live interface output variants" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :h3c) }
  let(:interfaces) { fixture("interfaces_s5130s") }
  let(:aggregation) { fixture("aggregation_s5130s") }

  # 加载精简的实际回显结构，并替换设备身份。
  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/h3c/#{name}.txt", __dir__))
  end

  # 验证公开契约时显式保留传输完整性。
  def parse(dimension, text, complete: true)
    parser.parse(dimension, text, complete: complete)
  end

  it "recognizes wrapped trunk VLAN metadata and internal interface details" do
    result = parse(:interfaces, interfaces)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:name] }).to eq(%w[Bridge-Aggregation10 GigabitEthernet1/0/1 InLoopBack0 NULL0])
    expect(result.records).to all(include(oper_status: :up, protocol_status: :up))
  end

  it "only consumes numeric continuations belonging to a VLAN list" do
    [ interfaces.sub("                 100-200", "                 damaged"),
      interfaces.sub("                 100-200", "                 4095"),
      interfaces.sub("                 100-200", "                 200-100"),
      interfaces.sub("Physical: InLoopBack", "Physical: InLoopBack\n                 100-200") ].each do |text|
      result = parse(:interfaces, text)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :unrecognized_interface_field))
    end
  end

  it "retains incompleteness, unfamiliar metadata and conflicting state diagnostics" do
    expect(parse(:interfaces, interfaces, complete: false).status).to eq(:partial)
    expect(parse(:interfaces, interfaces + "Unknown new field: enabled\n").status).to eq(:partial)
    result = parse(:interfaces, interfaces.sub("Current state: UP", "Current state: UP\nCurrent state: DOWN"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:oper_status]).to eq(:unknown)
  end

  it "keeps missing physical discard counts unavailable despite successful interface parsing" do
    result = parser.parse(:counters, interfaces, command: "display interface", complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(interface: "GigabitEthernet1/0/1", metric: :crc_errors, value: 0))
    expect(result.records).to include(include(interface: "GigabitEthernet1/0/1", metric: :in_discards, value: nil))
    expect(result.issues).not_to include(include(code: :unrecognized_interface_field))
  end

  it "normalizes explicit logical input and output drops without treating packet totals as errors" do
    text = interfaces.sub("Input: 0 packets, 0 bytes, 0 drops", "Input: 100 packets, 1000 bytes, 12 drops")
      .sub("Output: 0 packets, 0 bytes, 0 drops", "Output: 200 packets, 2000 bytes, 34 drops")
    result = parser.parse(:counters, text, command: "display interface", complete: true)

    expect(result.records).to include(include(interface: "InLoopBack0", metric: :in_discards, value: 12),
      include(interface: "InLoopBack0", metric: :out_discards, value: 34),
      include(interface: "NULL0", metric: :in_discards, value: 0),
      include(interface: "NULL0", metric: :out_discards, value: 0))
    expect(result.records.map { |row| row[:value] }).not_to include(100, 1000, 200, 2000)
  end

  it "does not interpret descriptions as CRC or directional discard evidence" do
    text = interfaces.sub("GigabitEthernet1/0/1\n", "GigabitEthernet1/0/1\nDescription: 99 CRC, Input: 100 packets, 1000 bytes, 88 drops\n")
    result = parser.parse(:counters, text, command: "display interface", complete: true)

    expect(result.records).to include(include(interface: "GigabitEthernet1/0/1", metric: :crc_errors, value: 0))
    expect(result.records.map { |row| row[:value] }).not_to include(99, 88)
    expect(result.issues).not_to include(include(code: :duplicate_counter))
  end

  it "keeps malformed or repeated logical drop measurements unknown" do
    source = "Input: 0 packets, 0 bytes, 0 drops"
    %w[-1 unavailable 1.5].each do |value|
      text = interfaces.sub(source, "Input: 100 packets, 1000 bytes, #{value} drops")
      result = parser.parse(:counters, text, command: "display interface", complete: true)

      expect(result.records).to include(include(interface: "InLoopBack0", metric: :in_discards, value: nil))
      expect(result.issues).to include(include(code: :invalid_counter_value, interface: "InLoopBack0", metric: :in_discards))
    end
    result = parser.parse(:counters, interfaces.sub(source, "#{source}\n#{source}"), command: "display interface", complete: true)
    expect(result.issues).to include(include(code: :duplicate_counter, interface: "InLoopBack0", metric: :in_discards))
    expect(result.records).not_to include(include(interface: "InLoopBack0", metric: :in_discards, value: 0))
  end

  it "removes role annotations from indexed local member identities and excludes remote actors" do
    result = parse(:aggregation, aggregation)
    expect(result).to be_complete
    expect(result.records.size).to eq(2)
    expect(result.records.map { |row| row[:member] }).to eq(%w[GigabitEthernet1/0/1 GigabitEthernet1/0/2])
    expect(result.records).to all(include(group: "Bridge-Aggregation10", member_status: :active, oper_status: :unknown))
  end

  it "normalizes the documented role markers without making unknown roles healthy" do
    %w[A M R].each do |marker|
      expect(parse(:aggregation, aggregation.sub("(R)", "(#{marker})"))).to be_complete
    end
    result = parse(:aggregation, aggregation.sub("(R)", "(Z)"))
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(member: "GigabitEthernet1/0/1(Z)"))
  end

  it "uses each local header to distinguish indexed tables from older two-column metadata" do
    result = parse(:aggregation, aggregation + fixture("aggregation").sub("Bridge-Aggregation10", "Bridge-Aggregation20").sub("Route-Aggregation20", "Route-Aggregation30"))
    expect(result).to be_complete
    expect(result.records.size).to eq(5)
    expect(result.records.last).to include(group: "Route-Aggregation30", member_status: :unselected)
  end

  it "rejects truncated indexed rows and missing local table headers" do
    [ aggregation.sub("32768    1        1", "32768    1"),
      aggregation.sub("  Port                Status   Priority Index    Oper-Key               Flag\n", "") ].each do |text|
      result = parse(:aggregation, text)
      expect(result.status).to eq(:partial)
      expect(result.records).not_to include(include(member: "GigabitEthernet1/0/1"))
    end
  end

  it "quarantines duplicate identities after role normalization" do
    text = aggregation.sub("  GE1/0/2             S", "  GE1/0/1             S")
    result = parse(:aggregation, text)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :duplicate_identity))
    expect(result.records).to be_empty
  end

  it "does not inherit a prior group for a malformed later group declaration" do
    text = aggregation + "Aggregate Interface: malformed group\nLocal:\nPort Status Priority Oper-Key\nGE1/0/9 S 32768 9\n"
    result = parse(:aggregation, text)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(member: "GigabitEthernet1/0/9"))
  end

  it "does not ignore unfamiliar local member states or incomplete collection" do
    expect(parse(:aggregation, aggregation.sub("GE1/0/1(R)          S", "GE1/0/1(R)          ?")).status).to eq(:partial)
    expect(parse(:aggregation, aggregation, complete: false).status).to eq(:partial)
  end

  it "retains an empty final local table as incomplete even after an earlier complete table" do
    result = parse(:aggregation, aggregation + "Local:\nPort Status Priority Index Oper-Key Flag\n")
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :aggregation_members_missing))
  end
end
