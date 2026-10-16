# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"
require "ctx_checker/hillstone/parsers/show_interface_counter"

RSpec.describe CtxChecker::Hillstone::Parsers::ShowInterfaceCounter do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/hillstone/interface_counters_live.txt", __dir__)) }

  # 解析采集到的列布局，不依赖平台级指标覆盖声明。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete)
  end

  it "projects discards for each returned online interface without inventing error or CRC totals" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records.size).to eq(10)
    expect(result.records.map { |row| row[:metric] }.uniq).to eq(%i[in_discards out_discards])
    expect(result.records).to include(
      include(interface: "xethernet0/25", metric: :in_discards, value: 522150539),
      include(interface: "xethernet0/25", metric: :out_discards, value: 0))
    expect(result.records).to all(include(discontinuity: nil))
    expect(result.records).not_to include(include(interface: "ethernet0/1"))
  end

  it "keeps 64-bit counts exact" do
    result = parse(text.sub("522150539", "18446744073709551615"))
    expect(result).to be_complete
    expect(result.records).to include(include(metric: :in_discards, value: 18_446_744_073_709_551_615))
  end

  it "does not count frame and byte totals as failed packets" do
    result = parse(text)
    expect(result.records.map { |row| row[:value] }).not_to include(1593908244371, 1908987537336880)
  end

  it "leaves malformed discard counts unavailable while retaining the other direction" do
    result = parse(text.sub("522150539", "-1"))
    expect(result.status).to eq(:partial)
    expect(result.records).to include(
      include(interface: "xethernet0/25", metric: :in_discards, value: nil),
      include(interface: "xethernet0/25", metric: :out_discards, value: 0))
    expect(result.issues).to include(include(code: :invalid_counter_value, metric: :in_discards))
  end

  it "marks truncated rows as incomplete rather than shifting column values" do
    result = parse(text.sub(/xethernet0\/25.*$/, "xethernet0/25 10 100 20 200 3"))
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(interface: "xethernet0/25"))
    expect(result.issues).to include(include(code: :unrecognized_counter_line))
  end

  it "removes duplicated interface metrics" do
    result = parse(text + text.lines.grep(/^xethernet0\/25/).join)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(interface: "xethernet0/25"))
    expect(result.issues).to include(include(code: :duplicate_identity))
  end

  it "refuses an unfamiliar column name instead of treating it as a discard counter" do
    result = parse(text.sub("in discard", "in unknown"))
    expect(result.status).to eq(:failed)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :unrecognized_counter_header))
  end

  it "does not confirm zero discards from an empty online-interface table" do
    result = parse(text.lines.first)
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :empty_counter_table))
  end

  it "keeps incomplete collection partial" do
    expect(parse(text, complete: false).status).to eq(:partial)
  end
end
