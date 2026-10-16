# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"
require "ctx_checker/radware_alteon/parsers/info_link"

RSpec.describe CtxChecker::RadwareAlteon::Parsers::InfoLink do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/link_5424_32415.txt", __dir__)) }

  # 解析器回归与命令调度逻辑分离。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete)
  end

  it "separates management and data port identities from configurable aliases" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records.size).to eq(30)
    expect(result.records).to include(
      include(name: "mgmt1", oper_status: :up),
      include(name: "mgmt2", oper_status: :down),
      include(name: "port1", oper_status: :up, admin_status: :unknown),
      include(name: "port3", oper_status: :down, admin_status: :down))
    expect(result.records).to all(include(kind: :physical, protocol_applicable: nil))
    expect(parse(text.sub(/^1        1/, "uplink   1")).records).to include(include(name: "port1"))
  end

  it "retains unfamiliar link states as unknown evidence" do
    result = parse(text.sub(/up$/, "testing"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:oper_status]).to eq(:unknown)
  end

  it "rejects truncated and duplicate rows without guessing port status" do
    truncated = parse(text + "29 29 10G full\n")
    expect(truncated.status).to eq(:partial)
    expect(truncated.records).not_to include(include(name: "port29"))
    duplicate = parse(text + text.lines.grep(/^mgmt     1/).join)
    expect(duplicate.status).to eq(:partial)
    expect(duplicate.records).not_to include(include(name: "mgmt1"))
  end

  it "keeps header-only and incomplete observations partial" do
    expect(parse(text.lines.first(3).join).status).to eq(:partial)
    expect(parse(text, complete: false).status).to eq(:partial)
  end

  it "does not interpret a different table or menu as link inventory" do
    expect(parse(text.sub("Flow Ctrl", "Other Ctrl")).status).to eq(:failed)
    expect(parse("[Information Menu]\n link - Show link information\n").status).to eq(:failed)
  end
end
