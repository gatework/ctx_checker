# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"
require "ctx_checker/radware_alteon/parsers/info_transceiver"

RSpec.describe CtxChecker::RadwareAlteon::Parsers::InfoTransceiver do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/transceiver_5424_32415.txt", __dir__)) }

  # 解析脱敏回显，不推断整个平台均具备光学能力。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete)
  end

  it "preserves directional readings in dBm without manufacturing alarm thresholds" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records.size).to eq(56)
    expect(result.records).to include(
      include(interface: "port1", metric: :tx_power, value: -1.98, present: true, dom_supported: true),
      include(interface: "port2", metric: :rx_power, value: -5.22, present: true, dom_supported: true))
    expect(result.records).to all(include(unit: :dbm, low_alarm: nil, low_warning: nil,
      high_alarm: nil, high_warning: nil, alarm: :unknown, applicable: nil))
  end

  it "keeps both short and long NA rows unknown without declaring modules absent" do
    result = parse(text)
    %w[port3 port21 port28].each do |name|
      expect(result.records.select { |row| row[:interface] == name }).to all(
        include(value: nil, present: nil, dom_supported: nil, applicable: nil))
    end
  end

  it "retains the other optical direction when one measurement is malformed" do
    result = parse(text.sub("-1.98", "NaN"))
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(interface: "port1", metric: :tx_power, value: nil),
      include(interface: "port1", metric: :rx_power, value: -1.78))
    overflow = parse(text.sub("-1.98", "9" * 400))
    expect(overflow.status).to eq(:partial)
    expect(overflow.records).to include(include(interface: "port1", metric: :tx_power, value: nil))
  end

  it "does not reinterpret reversed directions or a different unit as dBm measurements" do
    expect(parse(text.sub("Tx Power  Rx Power", "Rx Power  Tx Power")).records).to be_empty
    expect(parse(text.sub("(dBm)", "(mW)")).records).to be_empty
  end

  it "removes duplicate optical identities and retains truncated collection as partial" do
    duplicate = parse(text + text.lines.grep(/^ 1 /).join)
    expect(duplicate.status).to eq(:partial)
    expect(duplicate.records).not_to include(include(interface: "port1"))
    expect(parse(text, complete: false).status).to eq(:partial)
  end

  it "does not treat a truncated row as a valid unknown module" do
    result = parse(text + "29 NA NA NA\n")
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(interface: "port29"))
  end

  it "does not declare an empty or header-only response complete" do
    expect(parse("").status).to eq(:failed)
    expect(parse(text.lines.first(4).join).status).to eq(:partial)
  end
end
