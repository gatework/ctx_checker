# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"
require "ctx_checker/evaluator"

RSpec.describe "H3C controller hardware output variants" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :h3c) }

  # 仅保留已观察语法，设备测量值与接口身份使用合成数据。
  def parse(name, text)
    parser.parse(name, text, complete: true)
  end

  it "preserves power-supply identity across spaced slot headers and parenthesized watts" do
    text = [ 1, 2 ].map do |slot|
      <<~OUTPUT
        Slot #{slot} :
         Input Power: 100.0(W)
         PowerID State Mode Current(A) Voltage(V) Power(W) FanDirection
         1 Normal AC 4.0 12.0 48.0 --
         2 Normal AC 4.5 12.0 54.0 --
         3 Absent -- -- -- -- --
         4 Absent -- -- -- -- --
      OUTPUT
    end.join
    result = parse(:power, text)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:component] }).to eq([ 1, 2 ].flat_map { |slot| (1..4).map { |id| "slot #{slot}/power #{id}" } })
    expect(result.records.count { |row| row[:present] == true }).to eq(4)
    expect(result.records.select { |row| row[:present] == false }).to all(include(status: :absent, watts: nil))
    expect(result.records.first).to include(watts: 48.0)
  end

  it "does not discard malformed power metadata or duplicate supplies" do
    prefix = "Slot 1 :\nPowerID State Mode Current(A) Voltage(V) Power(W) FanDirection\n"
    row = "1 Normal AC 4.0 12.0 48.0 --\n"
    expect(parse(:power, prefix + row + "Input Power: 100.0(W) damaged\n").status).to eq(:partial)
    duplicate = parse(:power, prefix + row * 2)
    expect(duplicate.status).to eq(:partial)
    expect(duplicate.issues).to include(include(code: :duplicate_identity))
    expect(duplicate.records).to be_empty
  end

  it "retains sub-board sensor identities and each sensor's device thresholds" do
    text = <<~OUTPUT
      System Temperature information (degree centigrade):
      Slot Sensor Temperature LowerLimit WarningLimit AlarmLimit ShutdownLimit
      1 inflow 2 30 0 65 70 N/A
      1 inflow 2(sub1) 40 0 65 70 N/A
      1 hotspot 2(sub1) 72 0 95 112 N/A
      2 hotspot 2(sub1) 74 0 95 112 N/A
    OUTPUT
    result = parse(:temperature, text)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:component] }).to eq([ "slot 1/inflow 2", "slot 1/inflow 2(sub1)", "slot 1/hotspot 2(sub1)", "slot 2/hotspot 2(sub1)" ])
    expect(result.records.last).to include(value: 74, high_warning: 95, high_alarm: 112)
    expect(parse(:temperature, text.sub("2(sub1)", "2(sub?)")).status).to eq(:partial)
  end

  it "recognizes management-port traffic metadata without turning traffic counts into errors" do
    text = <<~OUTPUT
      M-GigabitEthernet0/0/0
      Current state: DOWN
      Line protocol state: DOWN
      Input (normal): 12 packets, 120 bytes,
               2 broadcasts, 3 multicasts, - pauses
      Input: 0 input errors, 0 runts, 0 giants, - throttles
               0 CRC, 0 frame, 0 overruns, - aborts
      Output: 0 output errors, 0 underrunns, - buffer failures
               - carrier, - no carrier
    OUTPUT
    result = parse(:interfaces, text)
    expect(result).to be_complete
    expect(result.records.first).to include(admin_status: :up, oper_status: :down, protocol_status: :down)
    counters = parser.parse(:counters, text, command: "display interface", complete: true)
    expect(counters.records).to include(include(metric: :crc_errors, value: 0))
    expect(counters.records.map { |row| row[:value] }).not_to include(2, 3, 12, 120)
    expect(parse(:interfaces, text.sub("- carrier, - no carrier", "- carrier, - no carrier damaged")).status).to eq(:partial)
  end

  it "keeps an absent protocol state unknown even on an explicitly identified stack port" do
    text = <<~OUTPUT
      Ten-GigabitEthernet1/1/15
      Current state: UP
      Media type is optical fiber, Port hardware type is STACK_SFP_PLUS, promiscuous mode: set
    OUTPUT
    result = parse(:interfaces, text)
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(oper_status: :up, protocol_status: :unknown)
    expect(result.issues).to include(include(code: :interface_state_missing))
  end

  it "records explicit unsupported optical diagnosis without inventing optical health" do
    text = "Ten-GigabitEthernet1/1/15 transceiver diagnostic information:\nThe transceiver does not support this function.\n"
    result = parse(:optics, text)
    expect(result).to be_complete
    expect(result.records).to all(include(present: true, dom_supported: false, value: nil))
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "h3c" }, observed_at: Time.now.utc, observations: { optics: result })
    findings = CtxChecker::Evaluator.new.call(snapshot).findings.select { |row| row.dimension == :optics }
    expect(findings).to all(have_attributes(status: :unknown, reason: :dom_unavailable))
    ambiguous = parse(:optics, text + "Unknown measurement\n")
    expect(ambiguous.status).to eq(:partial)
    expect(ambiguous.records).to all(include(present: nil, dom_supported: nil))
    expect(parse(:optics, text.sub("this function.", "this function according to old history.")).status).to eq(:failed)
  end
end
