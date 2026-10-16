# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"
require "ctx_checker/radware_alteon/parsers/info_l2_trunk"
require "ctx_checker/radware_alteon/parsers/info_l2_lacp_dump"

RSpec.describe CtxChecker::RadwareAlteon::Parsers::InfoL2Trunk do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/trunk_5424_32415.txt", __dir__)) }

  # 解析 trunk 转发状态，不虚构父接口链路状态。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete)
  end

  it "retains actual trunk members and leaves aggregate link state unknown" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records).to contain_exactly(
      include(group: "trunk1", member: "port27", member_status: :active, oper_status: :unknown),
      include(group: "trunk1", member: "port28", member_status: :active, oper_status: :unknown))
  end

  it "does not equate a blocking STP role with a failed physical link" do
    result = parse(text.sub("forwarding", "blocking"))
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(member_status: :unknown, oper_status: :unknown)
  end

  it "does not attach members of an unfamiliar group header to its predecessor" do
    result = parse(text + "Trunk group 2 with different header:\n  3: STG 1 forwarding\n")
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(member: "port3"))
    expect(parse(text + "Future aggregate information:\n  4: STG 1 forwarding\n").records)
      .not_to include(include(member: "port4"))
  end

  it "preserves missing membership as incomplete evidence" do
    result = parse(text.lines.first)
    expect(result.status).to eq(:partial)
    expect(result.records).to contain_exactly(include(group: "trunk1", member: nil))
  end

  it "removes duplicate identities and preserves incomplete input" do
    result = parse(text + "27: STG 1 forwarding\n")
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(member: "port27"))
    expect(parse(text, complete: false).status).to eq(:partial)
  end

  it "does not claim no configured trunks from empty output or a menu" do
    expect(parse("").status).to eq(:failed)
    expect(parse("[Layer 2 Menu]\n trunk - Show Trunk Group information\n").status).to eq(:failed)
  end
end

RSpec.describe CtxChecker::RadwareAlteon::Parsers::InfoL2LacpDump do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/lacp_5424_32415.txt", __dir__)) }

  # LACP 适用性独立于静态 trunk 成员表。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete)
  end

  it "confirms no active LACP only from the complete observed all-off table" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records).to be_empty
  end

  it "retains active or unfamiliar modes as an explicit adaptation gap" do
    result = parse(text.sub("off", "active"))
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :lacp_operational_evidence_unavailable, interface: "port1"))
  end

  it "does not trust disabled LACP with a selected or attached aggregator" do
    result = parse(text.sub(/1\s+off.*$/, "1 off 1 1 y 32768 1 1 n"))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :inconsistent_lacp_disabled_state))
  end

  it "requires nonempty, unique, and complete port rows before declaring LACP absent" do
    expect(parse(text.lines.first(3).join).status).to eq(:partial)
    expect(parse(text + text.lines.grep(/^1\s/).join).status).to eq(:partial)
    expect(parse(text + "29 off 29 29\n").status).to eq(:partial)
    expect(parse(text, complete: false).status).to eq(:partial)
    expect(parse("").status).to eq(:failed)
  end
end
