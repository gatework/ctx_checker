# frozen_string_literal: true

require_relative "spec_helper"
require "net/connector"
require "ctx_checker"

RSpec.describe CtxChecker::Collector do
  let(:target) { { host: "192.0.2.10", platform: "cisco_ios", model: "sample" } }
  let(:clock) { -> { Time.utc(2026, 10, 15, 8) } }
  let(:collector) { described_class.new(clock: clock) }
  let(:interfaces) do
    <<~TEXT
      GigabitEthernet1/0/1 is up, line protocol is up
        0 input errors, 0 CRC, 0 frame, 0 overrun, 0 ignored
        0 output errors, 0 collisions, 0 interface resets
    TEXT
  end
  let(:bgp) do
    <<~TEXT
      BGP router identifier 192.0.2.1, local AS number 65001
      Neighbor        V         AS MsgRcvd MsgSent   TblVer  InQ OutQ Up/Down  State/PfxRcd
      192.0.2.2       4      65002      10      10        1    0    0 00:10:00        0
    TEXT
  end

  def successful(body, command: "show interfaces")
    command_receipt(body, command: command, output: "command\n#{body}device#")
  end

  it "collects shared interface and counter output once, using the clean body and raw-output digest" do
    result = successful(interfaces)
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).once.and_return(result)
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[interfaces counters])
    expect(snapshot.observation(:interfaces).records.first[:name]).to eq("GigabitEthernet1/0/1")
    expect(snapshot.observation(:counters).records.map { |record| record[:metric] }).to include(:in_errors, :crc_errors, :out_errors)
    expect(snapshot.observation(:interfaces).evidence.first[:sha256]).to eq(Digest::SHA256.hexdigest(result.output))
    expect(snapshot.observation(:bgp).status).to eq(:not_requested)
    expect(snapshot.to_h.to_s).not_to include("device#")
  end

  it "leaves a borrowed session open and makes a real parser-to-report round trip" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "show ip bgp summary" ]).and_return(successful(bgp, command: "show ip bgp summary"))
    expect(session).not_to receive(:close)
    snapshot = collector.collect_session(target: target, session: session, dimensions: [ :bgp ])
    expect(CtxChecker::Evaluator.new.call(snapshot).findings).to include(have_attributes(dimension: :bgp, status: :pass))
  end

  it "keeps the first session failure and marks unsent commands without reconnecting" do
    error = Net::Connector::Error.new("private transport body", code: :connection_failed)
    session = double(:session)
    allow(session).to receive(:connected?).and_return(true, false, false)
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).and_return(
      double(:result, success?: false, steps: [], output: "", error: error))
    expect(session).not_to receive(:connect)
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[interfaces counters bgp])
    expect(snapshot.observation(:bgp).issues).to include(include(code: :connection_failed, skipped: true))
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.to_h.to_s).not_to include("private transport body")
  end

  it "continues independent queries after a command error while the session stays connected" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).and_return(successful("% Invalid input detected at '^' marker.\n", command: "show interfaces"))
    expect(session).to receive(:send_commands).with([ "show ip bgp summary" ]).and_return(successful(bgp, command: "show ip bgp summary"))
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[interfaces bgp])
    expect(snapshot.observation(:interfaces).status).to eq(:unsupported)
    expect(snapshot.observation(:bgp).records).not_to be_empty
  end

  it "records close failure without discarding completed observations" do
    session = double(:session, connected?: true)
    allow(session).to receive(:send_commands).and_return(successful(bgp, command: "show ip bgp summary"))
    connector = double(:connector)
    allow(connector).to receive(:open) do |&block|
      block.call(session)
      raise IOError, "secret close failure"
    end
    snapshot = collector.collect(target: target, connector: connector, dimensions: [ :bgp ])
    expect(snapshot.observation(:bgp).records).not_to be_empty
    expect(snapshot.issues).to include(code: :session_close_failed, stage: :close)
    expect(CtxChecker::Evaluator.new.call(snapshot).status).to eq(:unknown)
  end

  it "validates target and dimensions before opening a connection" do
    connector = double(:connector)
    expect(connector).not_to receive(:open)
    expect { collector.collect(target: target, connector: connector, dimensions: [ :arbitrary_script ]) }.to raise_error(ArgumentError)
    expect { collector.collect(target: target.merge(password: "secret"), connector: connector) }.to raise_error(ArgumentError)
  end

  it "rejects a connector platform mismatch before opening" do
    connector = double(:connector, platform: :palo_alto)
    expect(connector).not_to receive(:open)
    expect { collector.collect(target: target, connector: connector) }.to raise_error(ArgumentError, /platform/)
  end

  it "preserves a disconnected borrowed session as failed evidence" do
    session = double(:session, connected?: false)
    expect(session).not_to receive(:send_commands)
    snapshot = collector.collect_session(target: target, session: session, dimensions: [ :bgp ])
    expect(snapshot.observation(:bgp).issues).to include(include(code: :session_closed, skipped: true))
  end

  it "does not parse a zero-step success as completed evidence" do
    session = double(:session, connected?: true)
    allow(session).to receive(:send_commands).and_return(command_receipt(bgp, steps: []))
    snapshot = collector.collect_session(target: target, session: session, dimensions: [ :bgp ])
    expect(snapshot.observation(:bgp).status).to eq(:failed)
    expect(snapshot.observation(:bgp).issues).to include(include(code: :invalid_command_result, stage: :response, error_type: "TypeError"))
  end

  it "records a failed open without calling queries or leaking exception messages" do
    connector = double(:connector)
    allow(connector).to receive(:open).and_raise(Net::Connector::Error.new("credentials", code: :connection_failed))
    snapshot = collector.collect(target: target, connector: connector, dimensions: %i[interfaces bgp])
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:bgp).status).to eq(:failed)
    expect(snapshot.to_h.to_s).not_to include("credentials")
  end

  it "allows frozen clock instants without mutating them" do
    time = Time.new(2026, 10, 15, 8, 0, 0, "+08:00").freeze
    session = double(:session, connected?: true)
    allow(session).to receive(:send_commands).and_return(successful(bgp, command: "show ip bgp summary"))
    snapshot = described_class.new(clock: -> { time }).collect_session(target: target, session: session, dimensions: [ :bgp ])
    expect(snapshot.observation(:bgp).evidence.first[:observed_at]).to eq("2026-10-15T00:00:00.000000Z")
    expect(time.utc_offset).to eq(28_800)
  end

  it "collects shared system commands once and evaluates their independently scoped results" do
    session = double(:session, connected?: true)
    resources = File.read(File.expand_path("fixtures/ctx_checker/palo_alto/resources.txt", __dir__))
    environment = File.read(File.expand_path("fixtures/ctx_checker/palo_alto/environmentals.txt", __dir__))
    expect(session).to receive(:send_commands).with([ "show system resources" ]).once.ordered.and_return(successful(resources, command: "show system resources"))
    expect(session).to receive(:send_commands).with([ "show system environmentals" ]).once.ordered.and_return(successful(environment, command: "show system environmentals"))
    snapshot = collector.collect_session(target: target.merge(platform: "palo_alto"), session: session,
      dimensions: %i[cpu memory temperature environment power])
    expect(snapshot.observation(:cpu).records.first[:scope]).to eq("management_plane")
    expect(snapshot.observation(:cpu).evidence.map(&:to_h)).to eq(snapshot.observation(:memory).evidence.map(&:to_h))
    expect(snapshot.observation(:temperature).evidence.map(&:to_h)).to eq(snapshot.observation(:power).evidence.map(&:to_h))
    expect(CtxChecker::Evaluator.new.call(snapshot).findings.map(&:dimension)).to include(:cpu, :memory, :temperature, :power)
  end

  it "reports unsupported system dimensions without sending speculative commands" do
    session = double(:session, connected?: true)
    expect(session).not_to receive(:send_commands)
    snapshot = collector.collect_session(target: target.merge(platform: "cisco_nxos"), session: session, dimensions: [ :alarms ])
    expect(snapshot.observation(:alarms).status).to eq(:unsupported)
    expect(CtxChecker::Evaluator.new.call(snapshot).findings).to include(have_attributes(dimension: :alarms, status: :unknown))
  end
end
