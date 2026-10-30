# frozen_string_literal: true

require_relative "spec_helper"
require "net/connector"
require "ctx_checker"

RSpec.describe "CtxChecker bounded discovery collection" do
  let(:target) { { host: "192.0.2.55", platform: "cisco_ios" } }
  let(:collector) { CtxChecker::Collector.new(clock: -> { Time.utc(2026, 10, 16) }) }
  let(:interface_command) { "read interfaces" }
  let(:cpu_command) { "read cpu" }
  let(:counter_commands) { [ "read counters 1", "read counters 2" ] }
  let(:interface_parser) { Class.new(CtxParser::Parser) }
  let(:cpu_parser) { Class.new(CtxParser::Parser) }
  let(:counter_parser) { Class.new(CtxParser::Parser) }
  let(:static_entries) do
    [ { dimensions: [ :interfaces ], command: interface_command, parser: interface_parser },
      { dimensions: [ :cpu ], command: cpu_command, parser: cpu_parser } ]
  end
  let(:expanded_entries) do
    static_entries + counter_commands.map { |command| { dimensions: [ :counters ], command: command, parser: counter_parser } }
  end
  let(:profile_class) do
    Class.new(CtxParser::Profile) do
      def initialize(declarations:, expansion: nil)
        super()
        @declarations, @expansion = declarations, expansion
      end

      def commands = @declarations.by_dimension
      def parser_for(_name, command:) = @declarations.parsers.fetch(command)
      def discovery_dimensions(requested) = requested.include?(:counters) ? [ :interfaces ] : []
      def expand(observations, dimensions:) = @expansion ? @expansion.call(observations, dimensions) : self
    end
  end
  let(:expanded_profile) { build_profile(expanded_entries) }
  let(:profile) do
    build_profile(static_entries, expansion: lambda do |observations, _dimensions|
      interfaces = observations[:interfaces]
      ready = interfaces&.complete? && interfaces.records.all? { |row| row[:source_complete] != false }
      ready ? expanded_profile : profile
    end)
  end
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :cisco_ios) }

  def build_profile(entries, expansion: nil)
    profile_class.new(declarations: CtxParser::Commands.new(entries, multi_command: true), expansion: expansion)
  end

  def result(command, body = "sample")
    command_receipt(body, command: command, output: body)
  end

  def discovery(status: :complete, source_complete: true)
    CtxChecker::Observation.new(name: :interfaces, status: status,
      records: [ { name: "port1", kind: :physical, oper_status: :up, source_complete: source_complete } ],
      issues: status == :partial ? [ { code: :incomplete_output } ] : [],
      evidence: [ { command: interface_command, status: status } ])
  end

  before do
    allow(CtxChecker::ParserRegistry).to receive(:fetch).with("cisco_ios", model: nil, software_version: nil).and_return(profile)
    allow(interface_parser).to receive(:parse).and_return(CtxParser::Result.new(status: :complete,
      records: [ { name: "port1", kind: :physical, oper_status: :up }, { name: "port2", kind: :physical, oper_status: :down } ]))
    allow(cpu_parser).to receive(:parse).and_return(CtxParser::Result.new(status: :complete,
      records: [ { component: "MP", scope: "management_plane", utilization: 5 } ]))
    allow(counter_parser).to receive(:parse) do |text, complete:|
      CtxParser::Result.new(status: complete ? :complete : :partial,
        records: [ { interface: text, metric: :in_errors, value: 0 } ])
    end
  end

  it "discovers once, executes a bounded declarations, and leaves an unrequested dependency out of health" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ interface_command ]).once.ordered.and_return(result(interface_command))
    expect(session).to receive(:send_commands).with([ cpu_command ]).ordered.and_return(result(cpu_command))
    counter_commands.each_with_index do |command, index|
      expect(session).to receive(:send_commands).with([ command ]).ordered.and_return(result(command, "port#{index + 1}"))
    end
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[counters cpu])
    expect(snapshot.observation(:interfaces).status).to eq(:not_requested)
    expect(snapshot.observation(:cpu)).to be_complete
    expect(snapshot.observation(:counters)).to be_complete
    expect(snapshot.observation(:counters).records.map { |row| row[:interface] }).to eq(%w[port1 port2])
  end

  it "retains requested discovery results without querying them a second time" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ interface_command ]).once.and_return(result(interface_command))
    counter_commands.each_with_index do |command, index|
      expect(session).to receive(:send_commands).with([ command ]).and_return(result(command, "port#{index + 1}"))
    end
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[interfaces counters])
    expect(snapshot.observation(:interfaces)).to be_complete
    expect(snapshot.observation(:counters)).to be_complete
  end

  it "shares all requested views when a fixed command also supplies a discovery dependency" do
    static_entries[0][:dimensions] = %i[interfaces aggregation]
    shared_profile = build_profile(static_entries, expansion: ->(_observations, _dimensions) { expanded_profile })
    allow(CtxChecker::ParserRegistry).to receive(:fetch).with("cisco_ios", model: nil, software_version: nil).and_return(shared_profile)
    allow(interface_parser).to receive(:parse).and_return(CtxParser::Results.new(by_dimension: {
      interfaces: CtxParser::Result.new(status: :complete, records: [ { name: "port1" } ]),
      aggregation: CtxParser::Result.new(status: :complete, records: [])
    }))
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ interface_command ]).once.and_return(result(interface_command))
    counter_commands.each_with_index do |command, index|
      expect(session).to receive(:send_commands).with([ command ]).and_return(result(command, "port#{index + 1}"))
    end
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[aggregation counters])
    expect(snapshot.observation(:aggregation).status).to eq(:not_applicable)
    expect(snapshot.observation(:interfaces).status).to eq(:not_requested)
  end

  it "does not expand partial discovery and preserves its actual source diagnostics and evidence" do
    allow(interface_parser).to receive(:parse).and_return(CtxParser::Result.new(status: :partial,
      records: [ { name: "port1" } ], issues: [ { code: :truncated_port_table } ]))
    expect(profile).to receive(:expand).and_call_original
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ interface_command ]).and_return(result(interface_command))
    expect(session).to receive(:send_commands).with([ cpu_command ]).and_return(result(cpu_command))
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[counters cpu])
    counters = snapshot.observation(:counters)
    expect(counters.status).to eq(:failed)
    expect(counters.issues).to include(include(code: :discovery_unavailable), include(code: :truncated_port_table, command: interface_command))
    expect(counters.evidence.map(&:to_h)).to include(include(command: interface_command, status: :partial))
    expect(snapshot.observation(:cpu)).to be_complete
  end

  it "continues fixed checks when discovery expansion raises and suppresses exception messages" do
    allow(profile).to receive(:expand).and_raise(ArgumentError, "private port output")
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ interface_command ]).and_return(result(interface_command))
    expect(session).to receive(:send_commands).with([ cpu_command ]).and_return(result(cpu_command))
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[counters cpu])
    expect(snapshot.observation(:counters).issues).to include(include(code: :discovery_expansion_failed, error_type: "ArgumentError"))
    expect(snapshot.observation(:counters).evidence.map(&:to_h)).to include(include(command: interface_command, status: :complete))
    expect(snapshot.observation(:cpu)).to be_complete
    expect(snapshot.to_h.to_s).not_to include("private port output")
  end

  it "isolates one discovered command failure from the next port and fixed checks" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ interface_command ]).and_return(result(interface_command))
    expect(session).to receive(:send_commands).with([ cpu_command ]).and_return(result(cpu_command))
    expect(session).to receive(:send_commands).with([ counter_commands.first ]).and_raise(IOError, "private failure")
    expect(session).to receive(:send_commands).with([ counter_commands.last ]).and_return(result(counter_commands.last, "port2"))
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[counters cpu])
    expect(snapshot.observation(:counters).status).to eq(:partial)
    expect(snapshot.observation(:counters).records).to include(include(interface: "port2", value: 0))
    expect(snapshot.observation(:cpu)).to be_complete
  end

  it "preserves the first connection failure across discovery and never reconnects or submits later scripts" do
    connected = true
    session = double(:session)
    allow(session).to receive(:connected?) { connected }
    expect(session).to receive(:send_commands).with([ interface_command ]) do
      connected = false
      double(:result, success?: false, steps: [], output: "", error: Net::Connector::Error.new("private", code: :connection_failed))
    end
    expect(session).not_to receive(:send_commands).with([ cpu_command ])
    expect(session).not_to receive(:connect)
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[counters cpu])
    expect(snapshot.observation(:cpu).issues).to include(include(code: :connection_failed, skipped: true))
    expect(snapshot.observation(:counters).issues).to include(include(code: :connection_failed, command: interface_command))
  end

  it "marks a dependent dimension failed when opening fails before discovery" do
    connector = double(:connector)
    allow(connector).to receive(:open).and_raise(Net::Connector::Error.new("private", code: :connection_failed))
    snapshot = collector.collect(target: target, connector: connector, dimensions: [ :counters ])
    expect(snapshot.observation(:counters).status).to eq(:failed)
    expect(snapshot.observation(:counters).issues).to include(include(code: :connection_failed, stage: :connect))
  end

  it "expands immutable offline planning and parses only explicitly declared port commands" do
    expanded = parser.expand({ interfaces: discovery }, dimensions: [ :counters ])
    expect(expanded).not_to equal(parser)
    expect(parser.queries([ :counters ])).to be_empty
    expect(expanded.queries([ :counters ]).keys).to eq(counter_commands)
    observation = expanded.parse_outputs(:counters, counter_commands.zip(%w[port1 port2]).to_h, complete: true)
    expect(observation).to be_complete
    expect { expanded.parse_outputs(:counters, { "read unplanned 3" => "port3" }, complete: true) }.to raise_error(ArgumentError)
  end

  it "lets profiles reject missing, partial or internally incomplete offline discovery" do
    [ {}, { interfaces: discovery(status: :partial) }, { interfaces: discovery(source_complete: false) } ].each do |observations|
      expanded = parser.expand(observations, dimensions: [ :counters ])
      expect(expanded.parse_outputs(:counters, {}, complete: true).status).to eq(:failed)
      expect { expanded.parse_outputs(:counters, { counter_commands.first => "port1" }) }.to raise_error(ArgumentError)
    end
    expect { parser.expand({ interfaces: {} }, dimensions: [ :counters ]) }.to raise_error(ArgumentError)
  end

  it "lets a profile use complete physical source evidence despite an unrelated logical source failure" do
    logical_parser = Class.new(CtxParser::Parser)
    static_entries << { dimensions: [ :interfaces ], command: "read logical", parser: logical_parser }
    source_profile = build_profile(static_entries, expansion: lambda do |observations, _dimensions|
      interfaces = observations.fetch(:interfaces)
      ready = interfaces.evidence.any? { |entry| entry[:command] == interface_command && entry[:status] == :complete } &&
        interfaces.records.all? { |row| row[:source_complete] == true }
      ready ? expanded_profile : source_profile
    end)
    allow(CtxChecker::ParserRegistry).to receive(:fetch).with("cisco_ios", model: nil, software_version: nil).and_return(source_profile)
    allow(logical_parser).to receive(:parse).and_return(CtxParser::Result.new(status: :failed, issues: [ { code: :logical_ports_unavailable } ]))
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ interface_command ]).ordered.and_return(result(interface_command))
    expect(session).to receive(:send_commands).with([ "read logical" ]).ordered.and_return(result("read logical"))
    counter_commands.each_with_index do |command, index|
      expect(session).to receive(:send_commands).with([ command ]).ordered.and_return(result(command, "port#{index + 1}"))
    end
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[interfaces counters])
    expect(snapshot.observation(:interfaces).status).to eq(:partial)
    expect(snapshot.observation(:counters)).to be_complete
  end

  it "rejects a new view of a previously executed discovery command instead of crashing collection" do
    shared = build_profile([ static_entries.first.merge(dimensions: %i[interfaces counters]), static_entries.last ])
    allow(profile).to receive(:expand).and_return(shared)
    expect { parser.expand({ interfaces: discovery }, dimensions: [ :counters ]) }.to raise_error(ArgumentError, /reuse/)
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ interface_command ]).once.and_return(result(interface_command))
    expect(session).to receive(:send_commands).with([ cpu_command ]).and_return(result(cpu_command))
    snapshot = collector.collect_session(target: target, session: session, dimensions: %i[counters cpu])
    expect(snapshot.observation(:counters).issues).to include(include(code: :discovery_expansion_failed))
    expect(snapshot.observation(:cpu)).to be_complete
  end

  it "rejects expanded replacements of fixed commands before executing dynamic queries" do
    replacement = build_profile([ static_entries.first, static_entries.last.merge(command: "unrelated cpu") ] + expanded_entries.drop(2))
    allow(profile).to receive(:expand).and_return(replacement)
    expect { parser.expand({ interfaces: discovery }, dimensions: [ :counters ]) }.to raise_error(ArgumentError, /replace/)
  end

  it "rejects discovery fanout beyond its limit while accepting the exact boundary" do
    entries = static_entries + Array.new(513) { |index| { dimensions: [ :counters ], command: "read counters #{index}", parser: counter_parser } }
    allow(profile).to receive(:expand).and_return(build_profile(entries))
    expect { parser.expand({ interfaces: discovery }, dimensions: [ :counters ]) }.to raise_error(ArgumentError, /limit/)
    allow(profile).to receive(:expand).and_return(build_profile(entries.take(514)))
    expect(parser.expand({ interfaces: discovery }, dimensions: [ :counters ]).queries([ :counters ]).size).to eq(512)
  end

  it "validates fixed discovery declarations before opening the connector" do
    allow(profile).to receive(:discovery_dimensions).and_return([ :ospf ])
    connector = double(:connector)
    expect(connector).not_to receive(:open)
    expect { collector.collect(target: target, connector: connector, dimensions: [ :counters ]) }.to raise_error(ArgumentError, /Discovery/)
  end
end
