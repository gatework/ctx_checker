# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"
require "ctx_checker/evaluator"

RSpec.describe "H3C S5130S R6343 system captures" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :h3c) }

  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/h3c/#{name}_s5130s_r6343.txt", __dir__))
  end

  def parse(name, text = fixture(name), complete: true)
    parser.parse(name, text, complete: complete)
  end

  it "preserves the measured millisecond rather than rounding through a floating point second" do
    result = parse(:clock)
    expect(result.status).to eq(:complete)
    expect(result.records.first[:time]).to eq("2026-10-16T03:21:05.292Z")
    expect(result.records.first.values_at(:source, :synchronized)).to eq([ nil, nil ])
  end

  it "normalizes precise fractions and a negative offset across a calendar boundary" do
    %w[00.001 00.009 00.029 00.292 59.999].each do |seconds|
      source = "23:59:#{seconds} remote Fri 10/16/2026\nTime Zone : remote minus 08:00:00\n"
      expect(parse(:clock, source).records.first[:time]).to eq("2026-10-17T07:59:#{seconds}Z")
    end
  end

  it "keeps captured short CPU windows distinct from the one and five minute averages" do
    result = parse(:cpu)
    expect(result.status).to eq(:complete)
    expect(result.records.map { |row| row.values_at(:window_seconds, :utilization) }).to eq([ [ 5, 51 ], [ 60, 5 ], [ 300, 5 ] ])
  end

  it "uses the captured checked application memory total without mistaking FreeRatio for utilization" do
    result = parse(:memory)
    expect(result.status).to eq(:complete)
    expect(result.records.first).to include(total_bytes: 518_561_792, used_bytes: 229_318_656,
      free_bytes: 158_535_680, available_bytes: 289_243_136, basis: :used_minus_cache)
    expect(result.records.first[:utilization]).to be_within(0.001).of(44.222)
  end

  it "preserves every captured sensor and the device supplied limits" do
    result = parse(:temperature)
    expect(result.status).to eq(:complete)
    expect(result.records.size).to eq(8)
    expect(result.records.first).to include(value: 58, high_warning: 84, high_alarm: 98)
    expect(result.records.last).to include(value: 45, high_warning: 100, high_alarm: 110)
  end

  it "handles the compact fan state and unavailable power measurements independently" do
    expect(parse(:environment).status).to eq(:complete)
    expect(parse(:environment).records.first).to include(component: "slot 1/fan 1", status: :ok)
    expect(parse(:power).status).to eq(:complete)
    expect(parse(:power).records.first).to include(component: "slot 1/power 1", status: :ok, present: true, watts: nil)
  end

  it "retains module absence without fabricating DOM readings or zero optical power" do
    result = parse(:optics)
    expect(result.status).to eq(:complete)
    expect(result.records.size).to eq(8)
    expect(result.records).to all(include(present: false, dom_supported: nil, value: nil))
  end

  it "does not discard extra or contradictory output after an optical availability marker" do
    header = "Ten-GigabitEthernet1/0/49 transceiver diagnostic information:\n"
    [ "The transceiver is absent.\n", "The transceiver does not support digital diagnosis.\n" ].each do |state|
      [ "Unknown diagnostic field\n", state, "Current diagnostic parameters:\n" ].each do |tail|
        result = parse(:optics, header + state + tail)
        expect(result.status).to eq(:partial)
        expect(result.issues).to include(include(code: :ambiguous_optics_availability))
        expect(result.records).to all(include(present: nil, dom_supported: nil, value: nil))
      end
    end
  end

  it "keeps explicit unsupported DOM distinct from absence and malformed availability wording" do
    header = "Ten-GigabitEthernet1/0/49 transceiver diagnostic information:\n"
    result = parse(:optics, header + "The transceiver does not support digital diagnosis.\n")
    expect(result.status).to eq(:complete)
    expect(result.records).to all(include(present: true, dom_supported: false))
    result = parse(:optics, header + "The transceiver is absent according to old history.\n")
    expect(result.status).to eq(:failed)
    expect(result.records).to be_empty
  end

  it "does not replace the missing NTP offset with root delay, dispersion or jitter" do
    result = parse(:ntp)
    expect(result.status).to eq(:complete)
    expect(result.records.first).to include(synchronized: true, stratum: 3, peer_address: "192.0.2.123", reference: "192.0.2.123",
      leap: 0, offset_ms: nil)
  end

  it "identifies the explicit unconfigured OSPF response without manufacturing healthy peers" do
    result = parse(:ospf, fixture(:ospf_unconfigured))
    expect(result.status).to eq(:partial)
    expect(result.records).to be_empty
    expect(result.issues).to contain_exactly(include(code: :protocol_not_configured))
  end

  it "keeps an interrupted or empty OSPF response distinct from a confirmed unconfigured response" do
    result = parse(:ospf, fixture(:ospf_unconfigured), complete: false)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :incomplete_output))
    expect(parse(:ospf, "\n").status).to eq(:failed)
  end

  it "does not confirm OSPF configuration absence when other output contradicts or follows the marker" do
    [ "Unknown device warning\n", fixture(:ospf_unconfigured),
      "OSPF Process 1 with Router ID 192.0.2.1\n" ].each do |tail|
      result = parse(:ospf, fixture(:ospf_unconfigured) + tail)
      expect(result.issues).not_to include(include(code: :protocol_not_configured))
      expect(result.status).not_to eq(:complete)
    end
  end
end
