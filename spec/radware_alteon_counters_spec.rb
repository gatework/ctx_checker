# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"
require "ctx_checker/radware_alteon/parsers/stats_port_if"
require "ctx_checker/radware_alteon/parsers/stats_port_ether"

RSpec.describe CtxChecker::RadwareAlteon::Parsers::StatsPortIf do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/port_if_5424_32415.txt", __dir__)) }

  # 解析回归显式设置完整性，不依赖传输采集结果推断。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete)
  end

  it "retains four directional counters using the explicit port identity" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records).to contain_exactly(
      include(interface: "port27", metric: :in_discards, value: 0),
      include(interface: "port27", metric: :out_discards, value: 0),
      include(interface: "port27", metric: :in_errors, value: 0),
      include(interface: "port27", metric: :out_errors, value: 0))
    expect(result.records).to all(include(discontinuity: nil))
  end

  it "never replaces cumulative values with the per-second table" do
    result = parse(text.sub(/^Errors:.*$/, "Errors: 18446744073709551615 7"))
    expect(result).to be_complete
    expect(result.records).to include(include(metric: :in_errors, value: 18_446_744_073_709_551_615),
      include(metric: :out_errors, value: 7))
  end

  it "does not infer cumulative zeros from per-second values when a metric is absent" do
    result = parse(text.sub(/^Errors:.*\n/, ""))
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(metric: :in_errors, value: nil))
    expect(result.issues).to include(include(code: :counter_value_missing))
  end

  it "retains unavailable or malformed directional cells without changing the other direction" do
    expect(parse(text.sub(/^Errors:.*$/, "Errors: NA 3")).records)
      .to include(include(metric: :in_errors, value: nil), include(metric: :out_errors, value: 3))
    result = parse(text.sub(/^Errors:.*$/, "Errors: -1 2"))
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(metric: :in_errors, value: nil), include(metric: :out_errors, value: 2))
  end

  it "does not guess direction after an unfamiliar or reversed column header" do
    result = parse(text.sub("ifHCIn Counters       ifHCOut Counters", "ifHCOut Counters       ifHCIn Counters"))
    expect(result.status).to eq(:partial)
    expect(result.records).to all(include(value: nil))
  end

  it "invalidates repeated cumulative cells even when their numbers agree" do
    result = parse(text.sub("Per second", "Errors: 0 0\nPer second"))
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(metric: :in_errors, value: nil), include(metric: :out_errors, value: nil))
  end

  it "keeps missing, truncated, incomplete and duplicate-port evidence non-complete" do
    expect(parse("").status).to eq(:failed)
    expect(parse(text.lines.first(3).join).status).to eq(:partial)
    expect(parse(text, complete: false).status).to eq(:partial)
    duplicate = parse(text + text)
    expect(duplicate.status).to eq(:partial)
    expect(duplicate.records).to be_empty
  end

  it "recognizes an explicit rejected port as unavailable evidence" do
    result = parse("Error: bad port \"all\"\n[Statistics Menu]\n")
    expect(result.status).to eq(:failed)
    expect(result.records).to be_empty
  end

  it "binds dynamic query coverage to its expected port without mutable class state" do
    right = described_class.for_port(27)
    wrong = described_class.for_port(28)
    expect(right.parse(text, complete: true)).to be_complete
    result = wrong.parse(text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :counter_port_mismatch, interface: "port28"))
    expect(right.parse(text, complete: true)).to be_complete
    expect { described_class.for_port("27/clear") }.to raise_error(ArgumentError)
  end
end

RSpec.describe CtxChecker::RadwareAlteon::Parsers::StatsPortEther do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/port_ether_5424_32415.txt", __dir__)) }

  # IEEE 子计数器夹具与接口总计数器夹具分别保存。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete)
  end

  it "reports FCS and carrier counters without summing overlapping Ethernet subcounters" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records).to contain_exactly(
      include(interface: "port27", metric: :crc_errors, value: 0, discontinuity: nil, unit: :packets, scope: :mac),
      include(interface: "port27", metric: :out_carrier_errors, value: 0, discontinuity: nil, unit: :events, scope: :mac))
    expect(parse(text.sub(/^dot3StatsAlignmentErrors:.*$/, "dot3StatsAlignmentErrors: 100")).records)
      .to include(include(metric: :crc_errors, value: 0))
  end

  it "preserves unavailable and exact 64-bit counters" do
    result = parse(text.sub(/^dot3StatsFCSErrors:.*$/, "dot3StatsFCSErrors: 18446744073709551615"))
    expect(result.records).to include(include(metric: :crc_errors, value: 18_446_744_073_709_551_615))
    expect(parse(text.sub(/^dot3StatsFCSErrors:.*$/, "dot3StatsFCSErrors: NA")).records)
      .to include(include(metric: :crc_errors, value: nil))
  end

  it "leaves malformed and missing metrics unknown" do
    malformed = parse(text.sub(/^dot3StatsFCSErrors:.*$/, "dot3StatsFCSErrors: -1"))
    expect(malformed.status).to eq(:partial)
    expect(malformed.records).to include(include(metric: :crc_errors, value: nil))
    missing = parse(text.sub(/^dot3StatsFCSErrors:.*\n/, ""))
    expect(missing.status).to eq(:partial)
    expect(missing.records).to include(include(metric: :crc_errors, value: nil))
  end

  it "invalidates duplicate fields and duplicate port identities" do
    duplicate = parse(text + "dot3StatsFCSErrors: 0\n")
    expect(duplicate.status).to eq(:partial)
    expect(duplicate.records).to include(include(metric: :crc_errors, value: nil))
    expect(parse(text + text).records).to be_empty
  end

  it "does not transfer an unknown section counter to its previous port" do
    result = parse(text + "New statistics for port 9:\ndot3StatsFCSErrors: 8\n")
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(metric: :crc_errors, value: 0))
    expect(result.records).not_to include(include(interface: "port9"))
  end

  it "marks empty, truncated, and incomplete evidence unavailable" do
    expect(parse("").status).to eq(:failed)
    expect(parse(text.lines.first(2).join).status).to eq(:partial)
    expect(parse(text, complete: false).status).to eq(:partial)
  end

  it "rejects another port's Ethernet counters as evidence of the requested port" do
    result = described_class.for_port(28).parse(text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :counter_port_mismatch))
  end
end
