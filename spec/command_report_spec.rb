# frozen_string_literal: true

require_relative "spec_helper"
require "json"
require "ctx_checker"
require "ctx_checker/failure"

RSpec.describe CtxChecker::Report, "command outcomes" do
  def report(*observations)
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "h3c" },
      observed_at: Time.utc(2026, 10, 16), observations: observations.to_h { |row| [ row.name, row ] })
    CtxChecker::Evaluator.new.call(snapshot)
  end

  it "shows a rejected command separately from the successful next query" do
    interfaces = CtxChecker::Failure.observation(:interfaces, code: :command_failed, stage: :execute,
      command: "display interface", error: IOError.new("secret diagnostic"))
    cpu = CtxChecker::Observation.new(name: :cpu, status: :complete,
      records: [ { component: "cpu", scope: "system", utilization: 10 } ],
      evidence: [ { command: "display cpu-usage", status: :complete } ])
    result = report(interfaces, cpu)

    expect(result.commands).to include(include(command: "display interface", status: :failed,
      dimensions: { interfaces: :failed }, issues: [ include(code: :command_failed, stage: :execute, error_type: "IOError") ]))
    expect(result.commands).to include(include(command: "display cpu-usage", status: :complete))
    expect(result.to_text).to include("display interface", "execute:command_failed", "IOError")
    expect(result.to_h[:commands]).to eq(result.summary[:commands])
    expect(JSON.generate(result.summary)).not_to include("secret diagnostic")
    expect(result).not_to be_healthy
  end

  it "retains independent source outcomes inside a partially collected dimension" do
    counters = CtxChecker::Observation.new(name: :counters, status: :partial,
      records: [ { interface: "GigabitEthernet1/0/1", metric: :out_errors, value: 0, source_complete: true } ],
      evidence: [ { command: "display counters inbound interface", status: :failed },
        { command: "display counters outbound interface", status: :complete } ],
      issues: [ { command: "display counters inbound interface", code: :command_failed, stage: :execute } ])
    result = report(counters)

    expect(result.commands.map { |entry| entry.values_at(:command, :status) }).to eq([
      [ "display counters inbound interface", :failed ], [ "display counters outbound interface", :complete ] ])
    expect(result.commands.last[:issues]).to be_empty
    expect(result).not_to be_complete
  end

  it "reports a shared command with a failed view as partial and preserves both dimension statuses" do
    cpu = CtxChecker::Observation.new(name: :cpu, status: :complete,
      records: [ { component: "cpu", scope: "system", utilization: 10 } ],
      evidence: [ { command: "show system resources", status: :complete } ])
    memory = CtxChecker::Failure.observation(:memory, code: :invalid_observation, stage: :validate,
      command: "show system resources", error: ArgumentError.new("secret schema"))
    result = report(cpu, memory)

    expect(result.commands.size).to eq(1)
    expect(result.commands.first).to include(status: :partial, dimensions: { cpu: :complete, memory: :failed })
    expect(result.to_text).to include("validate:invalid_observation", "memory:failed")
    expect(result.commands).to be_frozen
    expect(result.commands.first[:dimensions]).to be_frozen
  end

  it "distinguishes commands never executed after session loss" do
    skipped = CtxChecker::Failure.observation(:bgp, code: :session_closed, stage: :session,
      command: "display bgp peer ipv4", skipped: true)
    result = report(skipped)

    expect(result.commands.first).to include(status: :skipped, dimensions: { bgp: :skipped })
    expect(result.to_text).to include("Command: skipped", "session:session_closed")
  end

  it "lists planned commands as skipped when opening the connection fails" do
    connector = double(:connector)
    allow(connector).to receive(:open).and_raise(IOError, "secret connection details")
    snapshot = CtxChecker::Collector.new.collect(target: { host: "192.0.2.1", platform: "h3c" },
      connector: connector, dimensions: %i[counters device_counters])
    result = CtxChecker::Evaluator.new.call(snapshot)

    expect(result.commands.map { |entry| entry[:command] }).to eq([
      "display interface", "display counters inbound interface", "display counters outbound interface" ])
    expect(result.commands.map { |entry| entry[:status] }).to all(eq(:skipped))
    expect(result.commands.first[:issues]).to include(include(code: :connection_failed, stage: :connect, error_type: "IOError"))
    expect(snapshot.observation(:device_counters).status).to eq(:unsupported)
    expect(result.to_h.to_s).not_to include("secret connection details")
  end

  it "keeps legacy evidence without source metadata conservative and omits unrequested commands" do
    row = CtxChecker::Observation.new(name: :counters, status: :partial,
      evidence: [ { command: "display counters inbound interface" }, { command: "display counters outbound interface" } ])
    result = report(row)

    expect(result.commands.size).to eq(2)
    expect(result.commands.map { |entry| entry[:status] }).to eq(%i[partial partial])
    expect(report.commands).to be_empty
  end

  it "preserves diagnostic order for one source and isolates unscoped diagnostics with multiple sources" do
    issues = [ { code: :incomplete_command_output }, { code: :command_failed, command: "read one" },
      { code: :incomplete_command_set }, { code: :parser_error, command: "read other" } ]
    single = CtxChecker::Observation.new(name: :counters, status: :partial, issues: issues,
      evidence: [ { command: "read one" }, { command: "read one", status: :failed }, { reference: "configuration" } ])
    entry = report(single).commands.fetch(0)
    expect(entry[:issues].map { |issue| issue[:code] }).to eq(%i[incomplete_command_output command_failed incomplete_command_set])
    expect(entry[:status]).to eq(:partial)

    multiple = CtxChecker::Observation.new(name: :counters, status: :partial, issues: issues,
      evidence: [ { command: "read one" }, { command: "read two" } ])
    entries = report(multiple).commands
    expect(entries.first[:issues].map { |issue| issue[:code] }).to eq([ :command_failed ])
    expect(entries.last[:issues]).to be_empty
  end
end
