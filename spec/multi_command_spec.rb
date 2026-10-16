# frozen_string_literal: true

require_relative "spec_helper"
require "net/connector"
require "ctx_checker"

RSpec.describe "CtxChecker multi-command observations" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :h3c) }
  let(:target) { { host: "192.0.2.40", platform: "h3c" } }
  let(:sample_time) { Time.utc(2026, 10, 16, 12) }
  let(:interface_command) { "display interface" }
  let(:inbound_command) { "display counters inbound interface" }
  let(:outbound_command) { "display counters outbound interface" }
  let(:interfaces) do
    <<~TEXT
      GigabitEthernet1/0/1
      Current state: UP
      Line protocol state: UP
      Input: 99 input errors
        5 CRC, 0 frame, 0 overruns, 0 aborts
      Output: 88 output errors
      Ten-GigabitEthernet1/0/2
      Current state: UP
      Line protocol state: UP
      Input: 77 input errors
        0 CRC, 0 frame, 0 overruns, 0 aborts
      Output: 66 output errors
      Bridge-Aggregation10
      Current state: UP
      Line protocol state: UP
    TEXT
  end
  let(:inbound) do
    <<~TEXT
      Interface Total (pkts) Broadcast (pkts) Multicast (pkts) Err (pkts)
      GE1/0/1 50000 20 30 2
      XGE1/0/2 60000 10 30 0
      BAGG10 110000 30 60 0
    TEXT
  end
  let(:outbound) do
    <<~TEXT
      Interface Total(pkts) Broadcast(pkts) Multicast(pkts) Err(pkts)
      GE1/0/1 100000 40 60 0
      XGE1/0/2 120000 20 60 7
      BAGG10 220000 60 120 0
    TEXT
  end
  let(:outputs) { { interface_command => interfaces, inbound_command => inbound, outbound_command => outbound } }

  def successful(command, body)
    step = Net::Connector::CommandResult.new(command: Net::Connector::Command.new(command),
      output: "#{command}\n#{body}<device>", prompt: "<device>", duration: 0.01)
    Net::Connector::Result.new(steps: [ step ], config: body)
  end

  def metric(observation, interface, name)
    observation.records.find { |row| row[:interface] == interface && row[:metric] == name }
  end

  def collect(session, dimensions: %i[interfaces counters], clock: -> { sample_time })
    CtxChecker::Collector.new(clock: clock).collect_session(target: target, session: session, dimensions: dimensions)
  end

  it "joins the three command bodies by normalized interface without inventing totals or discards" do
    result = parser.parse_outputs(:counters, outputs, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.evidence.map { |row| row[:command] }).to eq(outputs.keys)
    expect(metric(result, "GigabitEthernet1/0/1", :in_errors)).to include(value: 2, source_command: inbound_command)
    expect(metric(result, "GigabitEthernet1/0/1", :out_errors)).to include(value: 0, source_command: outbound_command)
    expect(metric(result, "GigabitEthernet1/0/1", :crc_errors)).to include(value: 5, source_command: interface_command)
    expect(metric(result, "Ten-GigabitEthernet1/0/2", :out_errors)).to include(value: 7)
    expect(metric(result, "Bridge-Aggregation10", :in_errors)).to include(value: 0)
    expect(metric(result, "GigabitEthernet1/0/1", :in_discards)).to include(value: nil)
    expect(result.records.map { |row| row[:interface] }.uniq).to match_array(%w[GigabitEthernet1/0/1 Ten-GigabitEthernet1/0/2 Bridge-Aggregation10])
    expect(result.records.map { |row| row[:value] }).not_to include(99, 88, 77, 66, 50000, 110000)
    expect(result.issues).not_to include(include(code: :incomplete_command_set))
    expect(result.issues).to include(include(code: :missing_counter_metrics))
  end

  it "requires an explicit source for a multi-command dimension and never treats one source as complete" do
    expect { parser.parse(:counters, inbound, complete: true) }.to raise_error(ArgumentError, /command|sources/)
    result = parser.parse_many([ :counters ], inbound, complete: true, command: inbound_command).fetch(:counters)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :incomplete_command_set))
    expect(result.records.map { |row| row[:metric] }.uniq).to eq([ :in_errors ])
    combined = parser.parse_many(%i[interfaces counters], interfaces, complete: true)
    expect(combined[:interfaces]).to be_complete
    expect(combined[:counters].status).to eq(:partial)
  end

  it "reports unsupported offline dimensions consistently without accepting invented commands" do
    parser = CtxChecker::RuntimeParser.new(platform: :cisco_nxos)
    observation = parser.parse_outputs(:alarms, {}, complete: true)
    expect(observation.to_h).to eq(parser.parse(:alarms, "", complete: true).to_h)
    expect(observation.status).to eq(:unsupported)
    [ nil, [], { "show invented alarms" => "no alarms" } ].each do |outputs|
      expect { parser.parse_outputs(:alarms, outputs, complete: true) }.to raise_error(ArgumentError)
    end
    expect { parser.parse_outputs(:missing, {}, complete: true) }.to raise_error(ArgumentError)
    expect { parser.parse_outputs(:alarms, {}, complete: :yes) }.to raise_error(ArgumentError)
  end

  it "retains absent directions and absent rows as unknown measurements" do
    missing_source = parser.parse_outputs(:counters, outputs.except(outbound_command), complete: true)
    expect(missing_source.status).to eq(:partial)
    expect(missing_source.issues).to include(include(code: :incomplete_command_set))
    expect(metric(missing_source, "GigabitEthernet1/0/1", :out_errors)).to include(value: nil, source_command: nil)
    missing_row = parser.parse_outputs(:counters, outputs.merge(outbound_command => outbound.lines.reject { |line| line.start_with?("XGE") }.join), complete: true)
    expect(missing_row.status).to eq(:partial)
    expect(metric(missing_row, "Ten-GigabitEthernet1/0/2", :out_errors)).to include(value: nil, source_command: nil)
    expect(missing_row.issues).to include(include(code: :counter_metrics_missing, interface: "Ten-GigabitEthernet1/0/2", metrics: include(:out_errors)))
  end

  it "rejects duplicate sources and quarantines duplicated counter identities within a source" do
    source = parser.parse(:counters, inbound, complete: true, command: inbound_command)
    expect { parser.combine(:counters, [ source, source ]) }.to raise_error(ArgumentError, /Duplicate source/)
    result = parser.parse_outputs(:counters, outputs.merge(inbound_command => inbound + "GE1/0/1 50001 20 30 9\n"), complete: true)
    expect(result.status).to eq(:partial)
    expect(metric(result, "GigabitEthernet1/0/1", :in_errors)).to include(value: nil)
    expect(result.issues).to include(include(code: :duplicate_identity))
    expect(metric(result, "GigabitEthernet1/0/1", :crc_errors)).to include(value: 5)
  end

  it "does not turn unsupported or invalid source bodies into healthy empty counters" do
    [ "Unrecognized command\n", "Error: permission denied\n", "\x00" ].each do |failure|
      result = parser.parse_outputs(:counters, outputs.merge(inbound_command => failure), complete: true)
      expect(result.status).to eq(:partial)
      expect(metric(result, "GigabitEthernet1/0/1", :in_errors)).to include(value: nil)
      expect(metric(result, "Ten-GigabitEthernet1/0/2", :out_errors)).to include(value: 7)
    end
    expect(parser.parse_outputs(:counters, outputs.transform_values { "Unrecognized command\n" }, complete: true).status).to eq(:unsupported)
    expect(parser.parse_outputs(:counters, {}, complete: true).status).to eq(:failed)
    expect { parser.parse_outputs(:counters, { "display unrelated" => inbound }, complete: true) }.to raise_error(ArgumentError)
  end

  it "preserves caller-declared incompleteness after all command sources are supplied" do
    result = parser.parse_outputs(:counters, outputs)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :incomplete_output))
    expect(result.issues).not_to include(include(code: :incomplete_command_set))
  end

  it "preserves a model parser's partial status even when it supplies no diagnostic issues" do
    metrics = { interface_command => :crc_errors, inbound_command => :in_errors, outbound_command => :out_errors }
    metrics.each do |command, metric|
      implementation = parser.profile.parser_for(:counters, command: command)
      allow(implementation).to receive(:parse).and_return(CtxParser::Result.new(status: :partial,
        records: [ { interface: "GigabitEthernet1/0/1", metric: metric, value: 0 } ]))
    end
    result = parser.parse_outputs(:counters, outputs, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :incomplete_command_output))
    expect(result.issues).not_to include(include(code: :incomplete_command_set))
  end

  it "queries shared interface state once and every counter source sequentially" do
    session = double(:session, connected?: true)
    outputs.each do |command, body|
      expect(session).to receive(:send_commands).with([ command ]).once.ordered.and_return(successful(command, body))
    end
    expect(session).not_to receive(:connect)
    expect(session).not_to receive(:close)
    snapshot = collect(session)
    expect(snapshot.observation(:interfaces)).to be_complete
    expect(snapshot.observation(:counters).evidence.map { |row| row[:command] }).to eq(outputs.keys)
    expect(snapshot.observation(:device_counters).status).to eq(:not_requested)
    expect(metric(snapshot.observation(:counters), "Ten-GigabitEthernet1/0/2", :out_errors)).to include(value: 7)
  end

  it "continues after one unsupported query without replacing successful source evidence" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ interface_command ]).ordered.and_return(successful(interface_command, interfaces))
    expect(session).to receive(:send_commands).with([ inbound_command ]).ordered.and_return(successful(inbound_command, "Unrecognized command\n"))
    expect(session).to receive(:send_commands).with([ outbound_command ]).ordered.and_return(successful(outbound_command, outbound))
    snapshot = collect(session)
    result = snapshot.observation(:counters)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :unsupported_command))
    expect(metric(result, "Ten-GigabitEthernet1/0/2", :out_errors)).to include(value: 7)
    expect(metric(result, "GigabitEthernet1/0/1", :in_errors)).to include(value: nil)
    expect(snapshot.observation(:interfaces)).to be_complete
  end

  it "stops after session loss and keeps prior CRC evidence without replay or reconnection" do
    connected = true
    session = double(:session)
    allow(session).to receive(:connected?) { connected }
    expect(session).to receive(:send_commands).with([ interface_command ]).ordered.and_return(successful(interface_command, interfaces))
    expect(session).to receive(:send_commands).with([ inbound_command ]).ordered do
      connected = false
      double(:result, success?: false, steps: [], output: "", error: Net::Connector::Error.new("private", code: :connection_failed))
    end
    expect(session).not_to receive(:send_commands).with([ outbound_command ])
    expect(session).not_to receive(:connect)
    snapshot = collect(session)
    result = snapshot.observation(:counters)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :connection_failed, skipped: true))
    expect(result.evidence.map { |row| row[:command] }).to eq(outputs.keys)
    expect(metric(result, "GigabitEthernet1/0/1", :crc_errors)).to include(value: 5)
    expect(metric(result, "GigabitEthernet1/0/1", :out_errors)).to include(value: nil)
    expect(snapshot.observation(:interfaces)).to be_complete
    expect(snapshot.to_h.to_s).not_to include("private")
  end

  it "retains the source timestamp on each metric instead of using the last command timestamp" do
    now = sample_time
    session = double(:session, connected?: true)
    outputs.each_with_index do |(command, body), index|
      expect(session).to receive(:send_commands).with([ command ]).ordered do
        now = sample_time + 1 + index * 10
        successful(command, body)
      end
    end
    result = collect(session, clock: -> { now }).observation(:counters)
    expect(metric(result, "GigabitEthernet1/0/1", :crc_errors)).to include(source_command: interface_command, sampled_at: (sample_time + 1).iso8601(6))
    expect(metric(result, "GigabitEthernet1/0/1", :in_errors)).to include(source_command: inbound_command, sampled_at: (sample_time + 11).iso8601(6))
    expect(metric(result, "GigabitEthernet1/0/1", :out_errors)).to include(source_command: outbound_command, sampled_at: (sample_time + 21).iso8601(6))
    expect(result.observed_at).to eq(sample_time + 21)
  end

  it "uses matching per-metric sample times for deltas even when evidence ended later" do
    row = { interface: "GigabitEthernet1/0/1", metric: :in_errors, value: 2, discontinuity: "verified-epoch", sampled_at: (sample_time + 10).iso8601(6) }
    previous_observation = CtxChecker::Observation.new(name: :counters, status: :complete, records: [ row ],
      evidence: [ { command: inbound_command, observed_at: (sample_time + 20).iso8601(6) } ])
    current_observation = CtxChecker::Observation.new(name: :counters, status: :complete,
      records: [ row.merge(value: 5, sampled_at: (sample_time + 70).iso8601(6)) ],
      evidence: [ { command: inbound_command, observed_at: (sample_time + 100).iso8601(6) } ])
    previous = CtxChecker::Snapshot.new(target: target, observed_at: sample_time + 30, observations: { counters: previous_observation })
    current = CtxChecker::Snapshot.new(target: target, observed_at: sample_time + 130, observations: { counters: current_observation })
    finding = CtxChecker::Evaluator.new.call(current, previous: previous).findings.find { |entry| entry.dimension == :counters }
    expect(finding.to_h).to include(status: :fail, reason: :counter_delta, actual: { delta: 3, seconds: 60.0 })
  end

  it "inherits offline source times before merging and detects a reversed individual sample" do
    combine = lambda do |inbound_seconds, other_seconds, value|
      sources = [ interface_command, inbound_command, outbound_command ].zip(%i[crc_errors in_errors out_errors]).map do |command, name|
        seconds = name == :in_errors ? inbound_seconds : other_seconds
        CtxChecker::Observation.new(name: :counters, status: :complete,
          records: [ { interface: "GigabitEthernet1/0/1", metric: name, value: name == :in_errors ? value : 0, discontinuity: "verified-epoch" } ],
          evidence: [ { command: command, observed_at: (sample_time + seconds).iso8601(6) } ])
      end
      parser.combine(:counters, sources)
    end
    previous_observation = combine.call(100, 0, 0)
    current_observation = combine.call(50, 200, 1)
    expect(metric(previous_observation, "GigabitEthernet1/0/1", :in_errors)[:sampled_at]).to eq((sample_time + 100).iso8601(6))
    expect(metric(current_observation, "GigabitEthernet1/0/1", :in_errors)[:sampled_at]).to eq((sample_time + 50).iso8601(6))
    expect(current_observation.observed_at).to eq(sample_time + 200)

    previous = CtxChecker::Snapshot.new(target: target, observed_at: sample_time + 180, observations: { counters: previous_observation })
    current = CtxChecker::Snapshot.new(target: target, observed_at: sample_time + 300, observations: { counters: current_observation })
    finding = CtxChecker::Evaluator.new.call(current, previous: previous).findings.find { |entry| entry.entity&.fetch(:metric, nil) == :in_errors }
    expect(finding.to_h).to include(status: :unknown, reason: :counter_sample_time_invalid)
  end

  it "keeps an explicit offline metric timestamp ahead of its source capture timestamp" do
    row = { interface: "GigabitEthernet1/0/1", metric: :in_errors, value: 0, sampled_at: (sample_time + 5).iso8601(6) }
    source = CtxChecker::Observation.new(name: :counters, status: :complete, records: [ row ],
      evidence: [ { command: inbound_command, observed_at: (sample_time + 20).iso8601(6) } ])
    result = parser.combine(:counters, [ source ])
    expect(metric(result, "GigabitEthernet1/0/1", :in_errors)[:sampled_at]).to eq((sample_time + 5).iso8601(6))
  end
end
