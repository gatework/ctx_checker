# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"
require "ctx_checker/hillstone/parsers/show_interface"

RSpec.describe CtxChecker::Hillstone::Parsers::ShowInterface do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/hillstone/interfaces_live.txt", __dir__)) }

  # 投影汇总状态，同时保留独立的聚合成员视图。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete).fetch(:interfaces)
  end

  it "retains physical and logical link states from a sanitized StoneOS capture" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records.size).to eq(8)
    expect(result.records).to include(
      include(name: "mgt0", admin_status: :up, oper_status: :up, protocol_status: :up, protocol_applicable: true),
      include(name: "xethernet0/24", oper_status: :up, protocol_status: :down, protocol_applicable: false),
      include(name: "vswitchif1", oper_status: :up, protocol_applicable: false),
      include(name: "ethernet0/1", oper_status: :down))
  end

  it "keeps incomplete collection partial even when every captured row is recognized" do
    result = parse(text, complete: false)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :incomplete_output))
  end

  it "rejects malformed addresses before using their state columns" do
    result = parse(text.sub("192.0.2.203/24", "999.0.2.203/24"))
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(name: "mgt0"))
    expect(result.issues).to include(include(code: :invalid_interface_address))
  end

  it "removes duplicated interface identities rather than trusting the last row" do
    result = parse(text + text.lines.grep(/^HA0/).join)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(name: "ha0"))
    expect(result.issues).to include(include(code: :duplicate_identity))
  end

  it "retains HA keep-up as unknown forwarding state" do
    result = parse(text.sub("U U U D", "U U K D"))
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(oper_status: :unknown)
    expect(result.issues).to include(include(code: :unknown_interface_state))
  end

  it "preserves the explicit LACP down state" do
    result = parse(text.sub("U U U D", "U U C D"))
    expect(result).to be_complete
    expect(result.records.first).to include(oper_status: :down)
  end

  it "does not count new or truncated interface rows as complete inventory" do
    result = parse(text + "ethernet0/2 0.0.0.0/0 NULL U U\n")
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :unrecognized_interface_line))
  end

  it "does not treat a header without interfaces as complete evidence" do
    result = parse(text.lines.reject { |line| line.match?(/^(?:HA|MGT|cellular|vswitchif|x?ethernet)/) }.join)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :interface_records_missing))
  end

  it "confirms no configured aggregates only from a complete summary" do
    result = described_class.new.parse(text, complete: true).fetch(:aggregation)
    expect(result).to be_complete
    expect(result.records).to be_empty
  end

  it "retains an aggregate failure without pretending its members were inspected" do
    result = described_class.new.parse(text.sub("ethernet0/1", "aggregate1"), complete: true)
    expect(result.fetch(:interfaces)).to be_complete
    expect(result.fetch(:aggregation).status).to eq(:partial)
    expect(result.fetch(:aggregation).records).to contain_exactly(include(group: "aggregate1", member: nil, oper_status: :down))
  end

  it "does not confirm a healthy link when physical and link state contradict" do
    result = parse(text.sub("U U U D", "D U U D"))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :inconsistent_interface_state))
  end

  it "keeps subinterface identity and parent together" do
    result = parse(text.sub("xethernet0/24", "xethernet0/24.100"))
    expect(result).to be_complete
    expect(result.records).to include(include(name: "xethernet0/24.100", kind: :subinterface, parent: "xethernet0/24"))
  end
end
