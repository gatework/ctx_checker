# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"
require "ctx_checker/hillstone/parsers/show_transceiver"

RSpec.describe CtxChecker::Hillstone::Parsers::ShowTransceiver do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/hillstone/optics_live.txt", __dir__)) }

  # 解析脱敏模块块，不依赖平台注册表。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete)
  end

  it "reads both modules and uses each module's reported normal range" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records.size).to eq(4)
    expect(result.records).to include(
      include(interface: "xethernet0/24", metric: :tx_power, value: -2.27, low_warning: -7.30, high_warning: -1.30),
      include(interface: "xethernet0/25", metric: :rx_power, value: -2.49, low_warning: -9.90, high_warning: -1.00))
    expect(result.records).to all(include(present: true, dom_supported: true, alarm: :unknown, low_alarm: nil, high_alarm: nil))
  end

  it "requires measurement units rather than treating a number with an unknown unit as dBm" do
    result = parse(text.sub(/-2\.27\s+dBm/, "-2.27 mW"))
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(value: nil)
    expect(result.issues).to include(include(code: :unrecognized_optics_field), include(code: :optics_measurement_missing))
  end

  it "invalidates a repeated measurement instead of choosing one sample" do
    result = parse(text.sub("Rx optical power:", "Tx optical power: -9.00 dBm\nRx optical power:"))
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(value: nil)
    expect(result.issues).to include(include(code: :duplicate_optics_value))
  end

  it "does not turn a missing threshold into an implicit healthy result" do
    result = parse(text.gsub(/^.*optical power normal range:.*\n/, ""))
    expect(result).to be_complete
    observation = CtxChecker::Observation.new(name: :optics, status: result.status, records: result.records)
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.203", platform: "hillstone" },
      observed_at: "2026-10-16T03:50:00Z", observations: { optics: observation })
    report = CtxChecker::Evaluator.new.call(snapshot)
    findings = report.findings.select { |finding| finding.dimension == :optics }
    expect(findings.map(&:reason)).to all(eq(:optical_thresholds_unavailable))
    expect(findings.map(&:status)).to all(eq(:unknown))
  end

  it "retains unmeasured DOM values without substituting zero power" do
    result = parse(text.sub(/-2\.27\s+dBm/, "N/A dBm"))
    expect(result).to be_complete
    expect(result.records.first).to include(value: nil, present: true, dom_supported: true)
  end

  it "does not attach an unfamiliar module header to the previous optical port" do
    result = parse(text.sub("xethernet0/25", "unknown-port"))
    expect(result.status).to eq(:partial)
    expect(result.records.size).to eq(2)
    expect(result.records).to all(include(interface: "xethernet0/24"))
    expect(result.issues).to include(include(code: :unrecognized_optics_block))
  end

  it "keeps duplicate module identities ambiguous" do
    result = parse(text.sub("xethernet0/25", "xethernet0/24"))
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :duplicate_identity))
  end

  it "does not treat a heading without module inventory as confirmed absence" do
    result = parse("Transceiver status information is shown as below:\n")
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to include(include(code: :optics_measurements_missing))
  end

  it "keeps incomplete device output partial" do
    expect(parse(text, complete: false).status).to eq(:partial)
  end

  it "accepts the documented warning-range labels without changing their severity" do
    result = parse(text.gsub("optical power normal range", "optical power warning range"))
    expect(result).to be_complete
    expect(result.records.first).to include(low_warning: -7.30, high_warning: -1.30)
  end
end
