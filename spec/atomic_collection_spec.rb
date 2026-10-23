# frozen_string_literal: true

require_relative "spec_helper"
require "net/connector"
require "ctx_checker"

RSpec.describe CtxChecker::Collector, "atomic command collection" do
  let(:target) { { host: "192.0.2.10", platform: "cisco_ios" } }
  let(:collector) { described_class.new(clock: -> { Time.utc(2026, 10, 16, 8) }) }
  let(:interfaces) { "GigabitEthernet1/0/1 is up, line protocol is up\n" }
  let(:bgp) do
    <<~TEXT
      BGP router identifier 192.0.2.1, local AS number 65001
      Neighbor        V         AS MsgRcvd MsgSent   TblVer  InQ OutQ Up/Down  State/PfxRcd
      192.0.2.2       4      65002      10      10        1    0    0 00:10:00        0
    TEXT
  end
  let(:session) { double(:session, connected?: true) }

  def successful(body)
    command_receipt(body, output: "command\n#{body}device#")
  end

  def expect_later_bgp
    expect(session).to receive(:send_commands).with([ "show ip bgp summary" ]).ordered.and_return(successful(bgp))
  end

  def collect(dimensions = %i[interfaces bgp], platform: "cisco_ios")
    collector.collect_session(target: target.merge(platform: platform), session: session, dimensions: dimensions)
  end

  # 实际连接器读取脚本化字节，不打开网络套接字。
  def scripted_device(*events)
    writes = []
    closed = true
    transport = double("Byte transport", protocol: :fake)
    allow(transport).to receive(:log_output=)
    allow(transport).to receive(:closed?) { closed }
    allow(transport).to receive(:open) { closed = false }
    allow(transport).to receive(:close) { closed = true }
    allow(transport).to receive(:write) { |bytes, **| writes << bytes; bytes.bytesize }
    allow(transport).to receive(:read) do |patterns, **|
      event = events.shift
      raise "Unexpected transport read" unless event
      next Net::Connector::Event.new(error: event) unless event.is_a?(String)

      body = event.b
      index = patterns.index { |pattern| pattern.match?(body) }
      raise "Missing expected prompt or interaction" unless index
      match = patterns[index].match(body)
      tail = body.byteslice(match.end(0)..)
      events.unshift(tail) unless tail.empty?
      Net::Connector::Event.new(index: index, before: body.byteslice(0, match.begin(0)), match: match[0])
    end
    device = Net::Connector.build(:cisco_ios, host: target[:host], username: "test-user", transport: transport)
    [ device, transport, events, writes ]
  end

  [ RuntimeError, ArgumentError ].each do |error_class|
    it "isolates #{error_class} from one command and continues the connected session" do
      expect(session).to receive(:send_commands).with([ "show interfaces" ]).ordered.and_raise(error_class, "secret runtime body")
      expect_later_bgp

      snapshot = collect
      failed = snapshot.observation(:interfaces)
      expect(failed.status).to eq(:failed)
      expect(failed.issues).to include(include(stage: :execute, error_type: error_class.name))
      expect(failed.evidence).to include(include(command: "show interfaces", status: :failed))
      expect(snapshot.observation(:bgp).status).to eq(:complete)
      expect(snapshot.to_h.to_s).not_to include("secret runtime body")
    end
  end

  [ Interrupt, SystemExit ].each do |error_class|
    it "propagates #{error_class} instead of converting cancellation into a failed command" do
      expect(session).to receive(:send_commands).with([ "show interfaces" ]).and_raise(error_class, "cancel collection")
      expect(session).not_to receive(:send_commands).with([ "show ip bgp summary" ])

      expect { collect }.to raise_error(error_class)
    end
  end

  it "accepts the explicit positional single-command session protocol" do
    commands = []
    responses = { "show interfaces" => successful(interfaces), "show ip bgp summary" => successful(bgp) }
    adapter = Object.new
    adapter.define_singleton_method(:connected?) { true }
    adapter.define_singleton_method(:send_commands) do |queries|
      commands << queries
      responses.fetch(queries.fetch(0))
    end

    snapshot = collector.collect_session(target: target, session: adapter, dimensions: %i[interfaces bgp])
    expect(snapshot.observation(:interfaces).status).to eq(:complete)
    expect(snapshot.observation(:bgp).status).to eq(:complete)
    expect(commands).to eq([ [ "show interfaces" ], [ "show ip bgp summary" ] ])
  end

  it "stops later commands when a missing receipt leaves completion unconfirmed" do
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).ordered.and_return(nil)
    expect(session).not_to receive(:send_commands).with([ "show ip bgp summary" ])

    snapshot = collect
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:interfaces).issues).to include(include(stage: :response))
    expect(snapshot.observation(:bgp).status).to eq(:failed)
    expect(snapshot.observation(:bgp).issues).to include(include(code: :invalid_command_result, skipped: true))
  end

  it "isolates a nontext result output without leaking its body" do
    malformed = double(:result, output: { password: "secret result body" }, success?: true, steps: successful(interfaces).steps)
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).ordered.and_return(malformed)
    expect(session).not_to receive(:send_commands).with([ "show ip bgp summary" ])

    snapshot = collect
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:interfaces).issues).to include(include(stage: :response))
    expect(snapshot.observation(:bgp).status).to eq(:failed)
    expect(snapshot.observation(:bgp).issues).to include(include(code: :invalid_command_result, skipped: true))
    expect(snapshot.to_h.to_s).not_to include("secret result body")
  end

  it "stops later commands when a zero-step success leaves completion unconfirmed" do
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).ordered.and_return(command_receipt(interfaces, steps: []))
    expect(session).not_to receive(:send_commands).with([ "show ip bgp summary" ])

    snapshot = collect
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:interfaces).issues).to include(include(stage: :response))
    expect(snapshot.observation(:bgp).status).to eq(:failed)
    expect(snapshot.observation(:bgp).issues).to include(include(code: :invalid_command_result, skipped: true))
  end

  it "classifies an exception reading a successful result body as a response failure" do
    malformed = double(:result, output: "raw\n", success?: true, steps: successful(interfaces).steps)
    allow(malformed).to receive(:value!).and_raise(ArgumentError, "secret extraction failure")
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).ordered.and_return(malformed)
    expect_later_bgp

    snapshot = collect
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:interfaces).issues).to include(include(stage: :response, error_type: "ArgumentError"))
    expect(snapshot.observation(:bgp).status).to eq(:complete)
    expect(snapshot.to_h.to_s).not_to include("secret extraction failure")
  end

  it "continues after a failed connector result while the transport remains connected" do
    error = Net::Connector::Error.new("secret rejected command", code: :command_failed)
    rejected = Net::Connector::Result.new(error: error)
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).ordered.and_return(rejected)
    expect_later_bgp

    snapshot = collect
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:bgp).status).to eq(:complete)
    expect(snapshot.to_h.to_s).not_to include("secret rejected command")
  end

  it "preserves earlier successful observations when a later command raises" do
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).ordered.and_return(successful(interfaces))
    expect(session).to receive(:send_commands).with([ "show etherchannel summary" ]).ordered.and_raise(RuntimeError, "secret aggregation failure")
    expect_later_bgp

    snapshot = collect(%i[interfaces aggregation bgp])
    expect(snapshot.observation(:interfaces).status).to eq(:complete)
    expect(snapshot.observation(:interfaces).records.first[:oper_status]).to eq(:up)
    expect(snapshot.observation(:aggregation).status).to eq(:failed)
    expect(snapshot.observation(:bgp).status).to eq(:complete)
    expect(snapshot.to_h.to_s).not_to include("secret aggregation failure")
  end

  it "does not reconnect a borrowed session after an execution exception closes it" do
    allow(session).to receive(:connected?).and_return(true, false)
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).and_raise(IOError, "secret transport body")
    expect(session).not_to receive(:send_commands).with([ "show ip bgp summary" ])
    expect(session).not_to receive(:connect)
    expect(session).not_to receive(:close)

    snapshot = collect
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:bgp).status).to eq(:failed)
    expect(snapshot.observation(:bgp).issues).to include(include(skipped: true))
    expect(snapshot.to_h.to_s).not_to include("secret transport body")
  end

  it "keeps completed facts when checking the session state raises" do
    reads = 0
    allow(session).to receive(:connected?) do
      reads += 1
      raise IOError, "secret session state" if reads > 1
      true
    end
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).and_return(successful(interfaces))
    expect(session).not_to receive(:send_commands).with([ "show ip bgp summary" ])
    expect(session).not_to receive(:connect)

    snapshot = collect
    expect(snapshot.observation(:interfaces).status).to eq(:complete)
    expect(snapshot.observation(:bgp).issues).to include(include(stage: :session, error_type: "IOError", skipped: true))
    expect(snapshot.to_h.to_s).not_to include("secret session state")
  end

  it "isolates a parser exception and still executes later commands" do
    allow(CtxChecker::CiscoIos::Parsers::ShowInterfaces).to receive(:parse).and_raise(RuntimeError, "secret parser body")
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).ordered.and_return(successful(interfaces))
    expect_later_bgp

    snapshot = collect
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:interfaces).issues).to include(include(stage: :parse, error_type: "RuntimeError"))
    expect(snapshot.observation(:bgp).status).to eq(:complete)
    expect(snapshot.to_h.to_s).not_to include("secret parser body")
  end

  it "retains a valid shared-command view when another view violates its schema" do
    cpu = CtxParser::Result.new(status: :complete, records: [ { component: "cpu", scope: "system", utilization: 10 } ])
    memory = CtxParser::Result.new(status: :complete, records: [ { component: "memory", scope: "system", utilization: 101 } ])
    allow(CtxChecker::CiscoNxos::Parsers::ShowSystemResources).to receive(:parse).and_return(
      CtxParser::Results.new(by_dimension: { cpu: cpu, memory: memory }))
    expect(session).to receive(:send_commands).with([ "show system resources" ]).once.and_return(successful("resources\n"))

    snapshot = collect(%i[cpu memory], platform: "cisco_nxos")
    expect(snapshot.observation(:cpu).status).to eq(:complete)
    expect(snapshot.observation(:cpu).records.first).to include(utilization: 10, source_complete: true)
    expect(snapshot.observation(:memory).status).to eq(:failed)
    expect(snapshot.observation(:memory).issues).to include(include(stage: :validate, error_type: "ArgumentError"))
  end

  it "retains a valid shared-command view when its sibling projection is missing" do
    cpu = CtxParser::Result.new(status: :complete, records: [ { component: "cpu", scope: "system", utilization: 10 } ])
    allow(CtxChecker::CiscoNxos::Parsers::ShowSystemResources).to receive(:parse).and_return(CtxParser::Results.new(by_dimension: { cpu: cpu }))
    expect(session).to receive(:send_commands).with([ "show system resources" ]).once.and_return(successful("resources\n"))

    snapshot = collect(%i[cpu memory], platform: "cisco_nxos")
    expect(snapshot.observation(:cpu).status).to eq(:complete)
    expect(snapshot.observation(:memory).status).to eq(:failed)
    expect(snapshot.observation(:memory).issues).to include(include(stage: :project, error_type: "KeyError"))
  end

  it "preserves outbound counter health when the independent inbound command fails" do
    detail = File.read(File.expand_path("fixtures/ctx_checker/h3c/interfaces.txt", __dir__))
    outbound = File.read(File.expand_path("fixtures/ctx_checker/h3c/counters_outbound.txt", __dir__))
    expect(session).to receive(:send_commands).with([ "display interface" ]).ordered.and_return(successful(detail))
    expect(session).to receive(:send_commands).with([ "display counters inbound interface" ]).ordered.and_raise(RuntimeError, "secret inbound failure")
    expect(session).to receive(:send_commands).with([ "display counters outbound interface" ]).ordered.and_return(successful(outbound))

    snapshot = collect(%i[interfaces counters], platform: "h3c")
    counters = snapshot.observation(:counters)
    expect(snapshot.observation(:interfaces).status).to eq(:complete)
    expect(counters.status).to eq(:partial)
    expect(counters.records).to include(include(interface: "GigabitEthernet1/0/1", metric: :out_errors, value: 0, source_complete: true))
    expect(counters.records).to include(include(interface: "GigabitEthernet1/0/1", metric: :in_errors, value: nil))
    expect(counters.evidence).to include(include(command: "display counters inbound interface", status: :failed))

    report = CtxChecker::Evaluator.new.call(snapshot)
    expect(report.findings).to include(have_attributes(dimension: :counters, status: :pass,
      entity: { interface: "GigabitEthernet1/0/1", metric: :out_errors }))
    expect(report.findings).to include(have_attributes(dimension: :counters, status: :unknown,
      entity: { interface: "GigabitEthernet1/0/1", metric: :in_errors }))
    expect(report.to_h.to_s).not_to include("secret inbound failure")
  end

  it "parses successful native queries after removing only command echo and prompt" do
    actual, transport, events, writes = scripted_device("router#",
      "show interfaces\r\n#{interfaces}router#", "show ip bgp summary\r\n#{bgp}router#")
    actual.connect
    snapshot = collector.collect_session(target: target, session: actual, dimensions: %i[interfaces bgp])
    expect(snapshot.observation(:interfaces).status).to eq(:complete)
    expect(snapshot.observation(:bgp).status).to eq(:complete)
    expect(snapshot.observation(:bgp).records.first[:state]).to eq(:established)
    expect(writes).to eq([ "show interfaces\n", "show ip bgp summary\n" ])
    expect(transport).to have_received(:open).once
    expect(events).to be_empty
  ensure
    actual&.close
  end

  it "preserves the native connector disconnect after CLI rejection and skips later queries" do
    actual, transport, events, writes = scripted_device("router#",
      "show interfaces\n% Invalid input detected at '^' marker.\nrouter#",
      "show ip bgp summary\n#{bgp}router#")
    actual.connect

    snapshot = collector.collect_session(target: target, session: actual, dimensions: %i[interfaces bgp])
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:interfaces).issues).to include(include(code: :device_error, stage: :execute))
    expect(snapshot.observation(:bgp).status).to eq(:failed)
    expect(snapshot.observation(:bgp).issues).to include(include(skipped: true))
    expect(actual).not_to be_connected
    expect(transport).to have_received(:open).once
    expect(transport).to have_received(:close).once
    expect(writes).to eq([ "show interfaces\n" ])
    expect(events.size).to eq(1)
  ensure
    actual&.close
  end

  it "keeps the connector's default close-on-rejection behavior outside atomic collection" do
    actual, transport, = scripted_device("router#", "% Invalid input detected at '^' marker.\nrouter#")
    actual.connect

    result = actual.execute_command("show interfaces")
    expect(result).to be_failure
    expect(actual).not_to be_connected
    expect(transport).to have_received(:open).once
    expect(transport).to have_received(:close).once
  ensure
    actual&.close
  end

  it "does not implicitly reconnect a real borrowed connector after transport loss" do
    actual, transport, events, writes = scripted_device("router#", :eof)
    actual.connect

    snapshot = collector.collect_session(target: target, session: actual, dimensions: %i[interfaces bgp])
    expect(snapshot.observation(:interfaces).status).to eq(:failed)
    expect(snapshot.observation(:bgp).issues).to include(include(skipped: true))
    expect(actual).not_to be_connected
    expect(transport).to have_received(:open).once
    expect(writes).to eq([ "show interfaces\n" ])
    expect(events).to be_empty
  ensure
    actual&.close
  end
end
