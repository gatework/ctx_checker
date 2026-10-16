# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"
require "ctx_checker/evaluator"

RSpec.describe "H3C Comware switch output variants" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :h3c) }

  # 使用合成接口、作用域、地址及读数保留实际回显语法。
  def parse(name, text)
    parser.parse(name, text, complete: true)
  end

  def findings(name, result)
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "h3c" },
      observed_at: Time.now.utc, observations: { name => result })
    CtxChecker::Evaluator.new.call(snapshot).findings.select { |row| row.dimension == name }
  end

  it "preserves a slot-only CPU scope without inventing a CPU identifier" do
    text = "Slot 1 CPU usage:\n 20% in last 5 seconds\n 3% in last 1 minute\n 2% in last 5 minutes\n"
    result = parse(:cpu, text)
    expect(result).to be_complete
    expect(result.records).to all(include(component: "slot 1"))
    expect(result.records.map { |row| row.values_at(:window_seconds, :utilization) }).to eq([ [ 5, 20 ], [ 60, 3 ], [ 300, 2 ] ])
    expect(parse(:cpu, text.sub("Slot 1 CPU usage:", "CPU usage:")).records).to be_empty
    expect(parse(:cpu, text + "2% in last 5 minutes\n").issues).to include(include(code: :duplicate_identity))
  end

  it "checks legacy byte totals against the rounded usage rate without claiming application memory health" do
    text = "System Total Memory(bytes): 10000\nTotal Used Memory(bytes): 4789\nUsed Rate: 47%\n"
    result = parse(:memory, text)
    expect(result).to be_complete
    expect(result.records.first).to include(component: "system", total_bytes: 10_000, used_bytes: 4789,
      free_bytes: nil, basis: :used_including_cache)
    expect(result.records.first[:utilization]).to be_within(0.001).of(47.89)
    expect(findings(:memory, result)).to all(have_attributes(status: :unknown, reason: :memory_basis_unavailable))

    [ text.sub("10000", "0"), text.sub("4789", "10001"), text.sub("47%", "90%"), text.sub("47%", "47oops"),
      text.sub("Used Rate: 47%\n", ""), text + "Total Used Memory(bytes): 4789\n" ].each do |invalid|
      parsed = parse(:memory, invalid)
      expect(parsed.status).to eq(:partial)
      expect(parsed.records.first[:utilization]).to be_nil
    end
    expect(parse(:memory, text + "Unknown memory scope\n").status).to eq(:partial)
  end

  it "retains unavailable old temperature measurements and unclassified limit severity as unknown" do
    text = <<~OUTPUT
      System Temperature information (degree centigrade):
      ----------------------------------------------------
      SlotNo    Temperature       Lower limit      Upper limit
      1         N/A               0                0
    OUTPUT
    result = parse(:temperature, text)
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(component: "slot 1", value: nil, high_alarm: nil, high_warning: nil)
    expect(result.issues).to include(include(code: :missing_temperature_measurement))
    expect(findings(:temperature, result)).to all(have_attributes(status: :unknown))
    measured = parse(:temperature, text.sub("N/A", "40"))
    expect(measured.records.first[:value]).to eq(40)
    expect(findings(:temperature, measured)).to all(have_attributes(status: :unknown))
  end

  it "keeps chassis sensor identities and auxiliary fan and power readings without fabricating limits" do
    text = <<~OUTPUT
      System temperature information (degree centigrade):
      Chassis Slot Sensor Temperature Lower Warning Alarm Shutdown
      1 0 outflow 1 35 0 68 82 NA
      2 0 outflow 1 37 0 68 82 NA
      Chassis 1:
      Fan temperature information:
      Fan 0: 36
      Power temperature information:
      Power 0: 46
      Chassis 2:
      Fan temperature information:
      Fan 0: 33
      Power temperature information:
      Power 0: 42
    OUTPUT
    result = parse(:temperature, text)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:component] }).to eq([ "chassis 1 slot 0/outflow 1", "chassis 2 slot 0/outflow 1",
      "chassis 1/fan 0", "chassis 1/power 0", "chassis 2/fan 0", "chassis 2/power 0" ])
    expect(result.records.first).to include(value: 35, low_warning: 0, high_warning: 68, high_alarm: 82)
    expect(result.records.last).to include(value: 42, high_warning: nil, high_alarm: nil)
    expect(findings(:temperature, result).select { |row| row.entity[:component].include?("/power") }).to all(have_attributes(status: :unknown))
    expect(parse(:temperature, text.sub("Chassis Slot", "Slot")).status).to eq(:partial)
    expect(parse(:temperature, text.sub("Power 0: 42", "Fan 0: 42")).issues).to include(include(code: :unrecognized_temperature_line))
  end

  it "parses indented legacy interface blocks and keeps genuinely absent line protocols unknown" do
    text = <<~OUTPUT
       GigabitEthernet1/0/1 current state: UP
       Tagged   VLAN ID : none
       Untagged VLAN ID : 100, 200
       Input: 10 input errors, 0 runts, - giants, - throttles
         8 CRC, - frame, 0 overruns, 2 aborts
       GigabitEthernet1/0/2 current state: DOWN
       Line protocol current state: DOWN
       Tagged   VLAN ID : 100-200
       Untagged VLAN ID : 300
       NULL0 current state: UP
       Line protocol current state: UP (spoofing)
       Physical is NULL DEV
         12 packets input, 120 bytes, 3 drops
         15 packets output, 150 bytes, 4 drops
    OUTPUT
    # 波浪线 heredoc 会移除公共缩进；此变体每行实际仍有一个前导空格。
    text = text.lines.map { |line| " #{line}" }.join
    result = parse(:interfaces, text)
    expect(result.records.size).to eq(3)
    expect(result.issues).to contain_exactly(include(code: :interface_state_missing, interface: "GigabitEthernet1/0/1"))
    expect(result.records.first).to include(oper_status: :up, protocol_status: :unknown)
    expect(result.records.last).to include(oper_status: :up, protocol_status: :up)
    counters = parser.parse(:counters, text, command: "display interface", complete: true)
    expect(counters.records).to include(include(interface: "GigabitEthernet1/0/1", metric: :crc_errors, value: 8),
      include(interface: "NULL0", metric: :in_discards, value: 3), include(interface: "NULL0", metric: :out_discards, value: 4))
    expect(counters.records.map { |row| row[:value] }).not_to include(10, 12, 120, 15, 150)
    expect(parse(:interfaces, text.sub("100-200", "100-5000")).issues).to include(include(code: :unrecognized_interface_field))
  end

  it "rejects negative, fractional and duplicate legacy drop counts" do
    prefix = "NULL0 current state: UP\nLine protocol current state: UP\n"
    [ "-1", "1.5" ].each do |value|
      result = parser.parse(:counters, prefix + "0 packets input, 0 bytes, #{value} drops\n", command: "display interface", complete: true)
      expect(result.issues).to include(include(code: :invalid_counter_value, metric: :in_discards))
      expect(result.records).to include(include(metric: :in_discards, value: nil))
    end
    duplicate = parser.parse(:counters, prefix + "0 packets input, 0 bytes, 1 drops\n" * 2, command: "display interface", complete: true)
    expect(duplicate.issues).to include(include(code: :duplicate_counter, metric: :in_discards))
    expect(duplicate.records).to be_empty
  end

  it "recognizes exact non-metric interface variants without swallowing unknown tails" do
    prefix = "LoopBack0\nCurrent state: UP\nLine protocol state: UP\n"
    metadata = <<~OUTPUT
      Known-unicast max-ratio: 100%
      Physical: Loopback
      Physical: Unknown
      0 broadcasts, 0 multicasts
      - frame,- overruns,- aborts,- ignored,- parity errors
    OUTPUT
    expect(parse(:interfaces, prefix + metadata)).to be_complete
    expect(parse(:interfaces, prefix + metadata.sub("0 multicasts", "0 multicasts invalid")).status).to eq(:partial)
  end

  it "accepts old NTP frequency and dispersion metadata without confusing them with the clock offset" do
    text = <<~OUTPUT
      Clock status: synchronized
      Clock stratum: 3
      Reference clock ID: 192.0.2.123
      Nominal frequency: 100.0000 Hz
      Actual frequency: 100.0000 Hz
      Clock offset: -0.7559 ms
      Peer dispersion: 29.89 ms
    OUTPUT
    result = parse(:ntp, text)
    expect(result).to be_complete
    expect(result.records.first).to include(synchronized: true, offset_ms: -0.7559, peer: nil)
    expect(parse(:ntp, text + "Clock status: unsynchronized\n").records.first[:synchronized]).to be_nil
  end

  it "keeps an explicit empty aggregation response distinct from a healthy group or an unsupported command" do
    text = " Info: No link aggregation group defined at present.\n"
    result = parse(:aggregation, text)
    expect(result.status).to eq(:not_applicable)
    expect(result.records).to be_empty
    expect(result.issues).to contain_exactly(include(code: :aggregation_not_configured))
    expect(parse(:aggregation, text + "Unknown trailing output\n").issues).not_to include(include(code: :aggregation_not_configured))
    expect(parse(:aggregation, "% Unrecognized command found at '^' position.\n").status).to eq(:unsupported)
  end

  it "does not infer module presence from an unsupported diagnostic operation" do
    prefix = "Ten-GigabitEthernet1/0/1 transceiver diagnostic information:\n"
    text = prefix + "The operation is not supported.\n"
    result = parse(:optics, text)
    expect(result).to be_complete
    expect(result.records).to all(include(present: nil, dom_supported: false, value: nil))
    expect(findings(:optics, result)).to all(have_attributes(status: :unknown, reason: :dom_unavailable))
    ambiguous = parse(:optics, text + "The transceiver is absent.\n")
    expect(ambiguous.status).to eq(:partial)
    expect(ambiguous.records).to all(include(present: nil, dom_supported: nil))
  end

  it "parses spaced OSPF role separators without inventing roles, VRFs or network types" do
    prefix = "OSPF Process 1 with Router ID 192.0.2.1\nNeighbor Brief Information\nArea: 0.0.0.0\nRouter ID Address Pri Dead-Time State Interface\n"
    text = prefix + "192.0.2.2 192.0.2.2 1 39 Full/ - FGE1/3/0/19\n192.0.2.3 192.0.2.3 1 37 Full/DR RAGG100\n"
    result = parse(:ospf, text)
    expect(result).to be_complete
    expect(result.records.size).to eq(2)
    expect(result.records.first).to include(state: :full, neighbor_role: :unknown, network_type: :unknown, vrf: nil)
    expect(result.records.last[:neighbor_role]).to eq(:dr)
    expect(parse(:ospf, text.sub("Full/ -", "Full/ INVALID")).status).to eq(:partial)
  end
end
