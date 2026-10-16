# frozen_string_literal: true

require_relative "spec_helper"
require "net/connector"
require "ctx_checker"

RSpec.describe "Configuration applicability through collection and reporting" do
  let(:target) { { host: "192.0.2.10", platform: "cisco_ios" } }
  let(:collector) { CtxChecker::Collector.new(clock: -> { Time.utc(2026, 10, 16, 8) }) }
  let(:optional_dimensions) { %i[aggregation bgp ospf] }
  let(:configuration) do
    <<~CONFIG
      version 15.2
      hostname example-switch
      !
      interface GigabitEthernet1/0/1
       no shutdown
      !
      end
    CONFIG
  end
  let(:interfaces) do
    <<~TEXT
      GigabitEthernet1/0/1 is up, line protocol is up
        0 input errors, 0 CRC, 0 frame, 0 overrun, 0 ignored
        0 output errors, 0 collisions, 0 interface resets
    TEXT
  end

  # 使用与实际顺序采集器一致的传输结果边界。
  def successful(body)
    step = Net::Connector::CommandResult.new(command: Net::Connector::Command.new("show example"),
      output: "command\n#{body}device#", prompt: "device#", duration: 0.01)
    Net::Connector::Result.new(steps: [ step ], config: body)
  end

  # 通过真实配置解析器确定适用性，不使用预设的判断替身。
  def applicability(text = configuration, complete: true, platform: :cisco_ios)
    CtxChecker::Applicability.from_configuration(platform: platform, text: text, complete: complete)
  end

  it "skips absent optional features while collecting a shared interface query exactly once" do
    context = applicability
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).once.and_return(successful(interfaces))
    snapshot = collector.collect_session(target: target, session: session,
      dimensions: [ :interfaces, :counters, *optional_dimensions ], applicability: context)

    optional_dimensions.each do |name|
      observation = snapshot.observation(name)
      expect(observation.status).to eq(:not_applicable)
      expect(observation.issues).to include(include(code: :feature_not_configured))
      expect(observation.evidence).to eq(context.evidence)
      expect(observation.records).to be_empty
    end
    expect(snapshot.observation(:interfaces)).to be_complete
    expect(snapshot.observation(:counters)).to be_complete
    expect(snapshot.observation(:interfaces).evidence).to eq(snapshot.observation(:counters).evidence)
  end

  it "does not open a connection when every requested dimension is inapplicable" do
    connector = double(:connector)
    expect(connector).not_to receive(:open)
    snapshot = collector.collect(target: target, connector: connector,
      dimensions: optional_dimensions, applicability: applicability)

    expect(optional_dimensions.map { |name| snapshot.observation(name).status }).to eq([ :not_applicable ] * 3)
    report = CtxChecker::Evaluator.new.call(snapshot)
    expect(report).to be_complete
    expect(report.counts[:unknown]).to eq(0)
    expect(report.counts[:pass]).to eq(0)
    expect(report.coverage).to eq(0.0)
    expect(report.findings.select { |finding| optional_dimensions.include?(finding.dimension) })
      .to all(have_attributes(status: :not_applicable, reason: :feature_not_configured))
  end

  it "does not inspect or close a borrowed session when all requested features are absent" do
    session = double(:session)
    expect(session).not_to receive(:connected?)
    expect(session).not_to receive(:send_commands)
    expect(session).not_to receive(:close)
    snapshot = collector.collect_session(target: target, session: session,
      dimensions: optional_dimensions, applicability: applicability)
    expect(snapshot.observation(:bgp).status).to eq(:not_applicable)
  end

  {
    aggregation: [ "interface Port-channel1\n no shutdown\n!\n", "show etherchannel summary" ],
    bgp: [ "router bgp 65001\n bgp router-id 192.0.2.1\n!\n", "show ip bgp summary" ],
    ospf: [ "router ospf 1\n router-id 192.0.2.1\n!\n", "show ip ospf neighbor" ]
  }.each do |name, (feature, command)|
    it "keeps configured #{name} with an empty runtime response unknown" do
      context = applicability(configuration.sub("end\n", "#{feature}end\n"))
      expect(context.not_applicable?(name)).to be(false)
      session = double(:session, connected?: true)
      expect(session).to receive(:send_commands).with([ command ]).and_return(successful(""))
      snapshot = collector.collect_session(target: target, session: session, dimensions: [ name ], applicability: context)
      expect(snapshot.observation(name).status).not_to eq(:not_applicable)
      report = CtxChecker::Evaluator.new.call(snapshot)
      expect(report.findings.select { |finding| finding.dimension == name }).to all(have_attributes(status: :unknown))
      expect(report).not_to be_complete
    end
  end

  it "does not skip queries when configuration completeness has not been established" do
    session = double(:session, connected?: true)
    [ "show etherchannel summary", "show ip bgp summary", "show ip ospf neighbor" ].each do |command|
      expect(session).to receive(:send_commands).with([ command ]).once.and_return(successful(""))
    end
    snapshot = collector.collect_session(target: target, session: session,
      dimensions: optional_dimensions, applicability: applicability(complete: false))
    expect(optional_dimensions.map { |name| snapshot.observation(name).status }).not_to include(:not_applicable)
  end

  it "does not let absent features bypass explicitly required dimensions" do
    snapshot = collector.collect_session(target: target, session: double(:unused_session),
      dimensions: optional_dimensions, applicability: applicability)
    policy = CtxChecker::Policy.new(required_dimensions: optional_dimensions)
    report = CtxChecker::Evaluator.new(policy: policy).call(snapshot)
    expect(report.findings.select { |finding| optional_dimensions.include?(finding.dimension) })
      .to all(have_attributes(status: :fail, reason: :required_feature_not_configured))
    expect(report.status).to eq(:fail)
    expect(report.coverage).to eq(100.0)
  end

  it "honors required members and peers even without required_dimensions" do
    snapshot = collector.collect_session(target: target, session: double(:unused_session),
      dimensions: optional_dimensions, applicability: applicability)
    policy = CtxChecker::Policy.new(required_members: { "Port-channel1" => [ "GigabitEthernet1/0/1" ] },
      expected_bgp: [ { vrf: "default", afi_safi: "ipv4_unicast", peer: "192.0.2.2" } ],
      expected_ospf: [ { vrf: "default", process_id: "1", interface: "GigabitEthernet1/0/1", router_id: "192.0.2.2" } ])
    report = CtxChecker::Evaluator.new(policy: policy).call(snapshot)
    expect(report.findings.select { |finding| optional_dimensions.include?(finding.dimension) })
      .to all(have_attributes(status: :fail, reason: :required_feature_not_configured))
  end

  it "rejects mismatched configuration platform before connection or borrowed session I/O" do
    context = applicability
    other_target = target.merge(platform: "cisco_nxos")
    connector = double(:connector)
    session = double(:session)
    expect(connector).not_to receive(:open)
    expect(session).not_to receive(:send_commands)
    expect(session).not_to receive(:connected?)
    expect do
      collector.collect(target: other_target, connector: connector, dimensions: optional_dimensions, applicability: context)
    end.to raise_error(ArgumentError, /platform/)
    expect do
      collector.collect_session(target: other_target, session: session, dimensions: optional_dimensions, applicability: context)
    end.to raise_error(ArgumentError, /platform/)
  end

  it "excludes optional absences from coverage without diluting applicable measurements" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).and_return(successful(interfaces))
    snapshot = collector.collect_session(target: target, session: session,
      dimensions: [ :interfaces, *optional_dimensions ], applicability: applicability)
    report = CtxChecker::Evaluator.new.call(snapshot)
    expect(report).to be_complete
    expect(report.status).to eq(:pass)
    expect(report.coverage).to eq(100.0)
    expect(report.counts[:unknown]).to eq(0)
    expect(report.commands.map { |entry| entry[:command] }).to include("show interfaces")
  end

  %i[bgp ospf].each do |name|
    it "recognizes complete Alteon #{name} disabled evidence without a configuration context" do
      parser = CtxChecker::RuntimeParser.new(platform: :radware)
      observation = parser.parse(name, "#{name.upcase} is disabled.\n", complete: true)
      expect(observation.status).to eq(:not_applicable)
      expect(parser.combine(name, [ observation ]).status).to eq(:not_applicable)
      snapshot = CtxChecker::Snapshot.new(target: target.merge(platform: "radware"), observed_at: Time.utc(2026, 10, 16),
        observations: { name => observation })
      report = CtxChecker::Evaluator.new.call(snapshot)
      expect(report.findings.select { |finding| finding.dimension == name })
        .to all(have_attributes(status: :not_applicable, reason: :feature_not_configured))

      incomplete = parser.parse(name, "#{name.upcase} is disabled.\n", complete: false)
      expect(incomplete.status).not_to eq(:not_applicable)
      expect(incomplete.issues).to include(include(code: :incomplete_output))
      expect(parser.parse(name, "#{name.upcase} is disabled.\nUnexpected neighbors\n", complete: true).status).not_to eq(:not_applicable)
    end
  end

  it "keeps Hillstone IPv4-only empty neighbor evidence inconclusive for the whole protocol" do
    parser = CtxChecker::RuntimeParser.new(platform: :hillstone)
    observation = parser.parse(:bgp, "No IPv4 neighbor is configured\n", complete: true)
    expect(observation.status).not_to eq(:not_applicable)
    expect(observation.issues).to include(include(code: :protocol_not_configured))
  end

  it "accepts an explicit complete zero aggregation count but not a blank or truncated response" do
    parser = CtxChecker::RuntimeParser.new(platform: :cisco_ios)
    body = "Number of channel-groups in use: 0\nNumber of aggregators: 0\n"
    expect(parser.parse(:aggregation, body, complete: true).status).to eq(:not_applicable)
    expect(parser.parse(:aggregation, body, complete: false).status).not_to eq(:not_applicable)
    expect(parser.parse(:aggregation, "", complete: true).status).to eq(:failed)

    commands = [ "show static groups", "show dynamic groups" ]
    sources = commands.map do |command|
      CtxChecker::Observation.new(name: :aggregation, status: :complete, evidence: [ { command: command, status: :complete } ])
    end
    expect(CtxChecker::ObservationMerger.call(:aggregation, sources, commands: commands).status).to eq(:not_applicable)
    expect(CtxChecker::ObservationMerger.call(:aggregation, sources.first(1), commands: commands).status).not_to eq(:not_applicable)
  end

  it "collects explicit H3C absence as inapplicable while preserving the completed command evidence" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "display link-aggregation verbose" ])
      .and_return(successful("Info: No link aggregation group defined at present.\n"))
    snapshot = collector.collect_session(target: target.merge(platform: "h3c"), session: session, dimensions: [ :aggregation ])
    expect(snapshot.observation(:aggregation).status).to eq(:not_applicable)
    report = CtxChecker::Evaluator.new.call(snapshot)
    expect(report).to be_complete
    expect(report.commands).to include(include(command: "display link-aggregation verbose", status: :complete))

    parser = CtxChecker::RuntimeParser.new(platform: :h3c)
    expect(parser.parse(:aggregation, "Info: No link aggregation group defined at present.\n", complete: false).status)
      .not_to eq(:not_applicable)
  end

  it "does not extend one absent source to an unavailable sibling command" do
    source = CtxChecker::Observation.new(name: :bgp, status: :not_applicable,
      issues: [ { code: :protocol_disabled } ], evidence: [ { command: "show protocol one", status: :complete } ])
    failure = CtxChecker::Observation.new(name: :bgp, status: :failed,
      issues: [ { code: :command_failed } ], evidence: [ { command: "show protocol two", status: :failed } ])
    commands = [ "show protocol one", "show protocol two" ]
    missing = CtxChecker::ObservationMerger.call(:bgp, [ source ], commands: commands)
    expect(missing.status).not_to eq(:not_applicable)
    expect(missing.issues).to include(include(code: :incomplete_command_set))
    combined = CtxChecker::ObservationMerger.call(:bgp, [ source, failure ], commands: commands)
    expect(combined.status).not_to eq(:not_applicable)
    expect(combined.issues).to include(include(code: :command_failed))
  end

  it "preserves a configuration and runtime contradiction instead of declaring the feature inapplicable" do
    context = applicability("sysname example-switch\n#\ninterface Bridge-Aggregation1\n description uplink\n#\nreturn\n", platform: :h3c)
    expect(context.state(:aggregation)).to eq(:configured)
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "display link-aggregation verbose" ])
      .and_return(successful("Info: No link aggregation group defined at present.\n"))
    snapshot = collector.collect_session(target: target.merge(platform: "h3c"), session: session,
      dimensions: [ :aggregation ], applicability: context)
    observation = snapshot.observation(:aggregation)
    expect(observation.status).to eq(:partial)
    expect(observation.issues).to include(include(code: :configuration_runtime_conflict))
    expect(observation.evidence).to include(*context.evidence)
    report = CtxChecker::Evaluator.new.call(snapshot)
    expect(report.findings.select { |finding| finding.dimension == :aggregation }).to all(have_attributes(status: :unknown))
    expect(report).not_to be_complete
  end
end
