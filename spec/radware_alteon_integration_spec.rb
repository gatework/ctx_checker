# frozen_string_literal: true

require_relative "spec_helper"
require "net/connector"
require "ctx_checker"

RSpec.describe "Alteon runtime integration" do
  let(:target) { { host: "192.0.2.250", platform: "radware", model: "Alteon 5424 S Perform" } }
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :radware, model: target[:model]) }

  # 设备衍生样本已经脱敏，测试不需要实时连接。
  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/#{name}.txt", __dir__))
  end

  # 保留两个实际端口的布局，以及已观察到的管理端口和表格语法。
  def two_port_link
    fixture("link_5424_32415").lines.reject do |line|
      match = /\A\d+\s+(\d+)\s/.match(line)
      match && ![ 27, 28 ].include?(match[1].to_i)
    end.join
  end

  # 连接器可返回传输有效的结果，但其 CLI 正文仍可能明确报错。
  def response(command, body)
    command_receipt(body, command: command, output: "#{command}\n#{body}>> Main#")
  end

  # 为目录边界回归构造类型化的发现证据。
  def inventory(names, status: :complete, source_complete: true)
    CtxChecker::Observation.new(name: :interfaces, status: status,
      records: names.map { |name| { name: name, kind: :physical, source_complete: source_complete } },
      evidence: [ { command: "/info/link", status: status } ])
  end

  it "resolves Alteon aliases and shares SP and NTP queries across their views" do
    %i[radware alteon radware_alteon].each do |name|
      expect(CtxChecker::ParserRegistry.canonical(name)).to eq("radware_alteon")
      expect(CtxChecker::ParserRegistry.fetch(name)).to be_a(CtxChecker::RadwareAlteon::Profile)
    end
    queries = parser.queries(CtxChecker::RuntimeParser::DIMENSIONS)
    expect(queries.fetch("/stats/sp 1/allutils")).to eq(%i[cpu memory])
    expect(queries.fetch("/stats/sys/ntp")).to eq(%i[ntp device_counters])
    expect(queries.keys).to all(match(%r{\A/(?:info|stats)/[a-z0-9 /]+\z}))
    expect(parser.profile.commands.keys).not_to include(:counters, :alarms, :optics)
  end

  it "rejects an explicitly different Radware product before opening a connection" do
    connector = double(:connector)
    expect(connector).not_to receive(:open)
    %w[DefensePro defense-pro DEFENSE_PRO].each do |model|
      expect do
        CtxChecker::Collector.new.collect(target: target.merge(model: model), connector: connector, dimensions: [ :cpu ])
      end.to raise_error(ArgumentError, /DefensePro/)
    end
  end

  it "preserves a selected model parser through firmware gating and port discovery" do
    variant = Class.new(CtxChecker::RadwareAlteon::Parsers::InfoSysGeneral)
    profile_class = Class.new(CtxChecker::RadwareAlteon::Profile)
    profile_class.const_set(:MODEL_PARSERS, { "fixture-model" => { "/info/sys/general" => variant } })
    selected = profile_class.new(model: " FIXTURE-MODEL ")
    configured = selected.with_software_version("32.4.15.0")
    expanded = configured.expand({ interfaces: inventory([ "port27" ]) }, dimensions: [ :counters ])

    [ selected, configured, expanded ].each do |profile|
      expect(profile.parser_for(:clock)).to equal(variant)
      expect(profile.parser_for(:power)).to equal(CtxChecker::RadwareAlteon::Parsers::InfoSysPs)
    end
    expect(profile_class.new.parser_for(:clock)).to equal(CtxChecker::RadwareAlteon::Parsers::InfoSysGeneral)
    expect(variant).to receive(:parse).with("model syntax", complete: true)
      .and_return(CtxParser::Result.new(status: :complete))
    expect(expanded.parse(:clock, "model syntax", complete: true)).to be_complete
    expect(expanded.parser_for(:counters, command: "/stats/port 27/if")).to be < CtxChecker::RadwareAlteon::Parsers::StatsPortIf
    expect(expanded.commands_for(:optics)).to eq([ "/info/transceiver" ])
    expect(selected.commands).not_to have_key(:optics)
    expect(configured.commands).not_to have_key(:counters)
  end

  it "rejects model overrides for commands outside the fixed platform declaration" do
    [ "/stats/port 27/if", "/info/transceiver", "/info/invented" ].each do |command|
      profile_class = Class.new(CtxChecker::RadwareAlteon::Profile)
      profile_class.const_set(:MODEL_PARSERS,
        { "fixture-model" => { command => CtxChecker::RadwareAlteon::Parsers::InfoSysGeneral } })
      expect { profile_class.new(model: "fixture-model") }.to raise_error(ArgumentError, /Model parsers/)
    end
  end

  it "expands only complete numbered port evidence and keeps the original profile immutable" do
    discovery = parser.parse(:interfaces, fixture("link_5424_32415"), complete: true, command: "/info/link")
    expanded = parser.expand({ interfaces: discovery }, dimensions: [ :counters ])
    expect(parser.profile.commands).not_to have_key(:counters)
    commands = expanded.profile.commands_for(:counters)
    expect(commands.size).to eq(56)
    expect(commands).to start_with("/stats/port 1/if", "/stats/port 1/ether")
    expect(commands).to end_with("/stats/port 28/if", "/stats/port 28/ether")
    expect(commands).not_to include("/stats/port all/if", "/stats/port mgmt1/if")
    expect(expanded.profile.expand({ interfaces: discovery }, dimensions: [ :counters ])).to equal(expanded.profile)
    expect(parser.profile.expand({ interfaces: discovery }, dimensions: [ :cpu ])).to equal(parser.profile)
  end

  it "leaves missing, partial and individually incomplete discoveries unavailable" do
    [ {}, { interfaces: inventory([ "port1" ], status: :partial) },
      { interfaces: inventory([ "port1" ], source_complete: false) },
      { interfaces: inventory([ "mgmt1" ]) } ].each do |observations|
      expanded = parser.expand(observations, dimensions: [ :counters ])
      expect(expanded.profile.commands).not_to have_key(:counters)
      expect(expanded.unavailable_observation(:counters).status).to eq(:failed)
    end
  end

  it "bounds discovery to exact positive port identifiers and at most 512 added queries" do
    %w[port0 port01 port257 port1/if port1;save].each do |name|
      expect do
        parser.expand({ interfaces: inventory([ name ]) }, dimensions: [ :counters ])
      end.to raise_error(ArgumentError, /port identity/)
    end
    expanded = parser.expand({ interfaces: inventory((1..256).map { |port| "port#{port}" }) }, dimensions: [ :counters ])
    expect(expanded.profile.commands_for(:counters).size).to eq(512)
  end

  it "rejects a valid counter reply belonging to another requested port" do
    expanded = parser.expand({ interfaces: inventory([ "port28" ]) }, dimensions: [ :counters ])
    %w[if ether].each do |kind|
      observation = expanded.parse(:counters, fixture("port_#{kind}_5424_32415"),
        complete: true, command: "/stats/port 28/#{kind}")
      expect(observation.status).to eq(:partial)
      expect(observation.records).to be_empty
      expect(observation.issues).to include(include(code: :counter_port_mismatch))
    end
  end

  it "continues across a rejected port query and preserves other port and CPU evidence" do
    commands = []
    session = double(:session, connected?: true)
    allow(session).to receive(:send_commands) do |batch|
      command = batch.fetch(0)
      commands << command
      body = case command
      when "/info/link" then two_port_link
      when "/info/l3/ip" then fixture("ip_5424_32415")
      when "/stats/mp/cpu" then fixture("mp_cpu_5424_32415")
      when "/stats/sp 1/allutils" then fixture("sp_allutils_5424_32415")
      when "/stats/port 27/if" then fixture("command_error")
      when %r{\A/stats/port (27|28)/(if|ether)\z}
        fixture("port_#{Regexp.last_match(2)}_5424_32415").sub("port 27:", "port #{Regexp.last_match(1)}:")
      else raise "Unexpected query"
      end
      response(command, body)
    end
    snapshot = CtxChecker::Collector.new.collect_session(target: target, session: session, dimensions: %i[counters cpu])
    expect(commands).to eq([ "/info/link", "/info/l3/ip", "/stats/mp/cpu", "/stats/sp 1/allutils",
      "/stats/port 27/if", "/stats/port 27/ether", "/stats/port 28/if", "/stats/port 28/ether" ])
    expect(snapshot.observation(:cpu)).to be_complete
    counters = snapshot.observation(:counters)
    expect(counters.status).to eq(:partial)
    expect(counters.records.select { |row| row[:interface] == "port28" }).to all(include(value: 0, source_complete: true))
    expect(counters.issues).to include(include(code: :command_error))
  end

  it "continues fixed system queries after failed discovery without generating any port commands" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "/info/link" ]).ordered.and_return(response("/info/link", fixture("command_error")))
    expect(session).to receive(:send_commands).with([ "/info/l3/ip" ]).ordered.and_return(response("/info/l3/ip", fixture("ip_5424_32415")))
    expect(session).to receive(:send_commands).with([ "/stats/mp/cpu" ]).ordered.and_return(response("/stats/mp/cpu", fixture("mp_cpu_5424_32415")))
    expect(session).to receive(:send_commands).with([ "/stats/sp 1/allutils" ]).ordered.and_return(response("/stats/sp 1/allutils", fixture("sp_allutils_5424_32415")))
    snapshot = CtxChecker::Collector.new.collect_session(target: target, session: session, dimensions: %i[counters cpu])
    expect(snapshot.observation(:counters).status).to eq(:failed)
    expect(snapshot.observation(:counters).issues).to include(include(code: :discovery_unavailable))
    expect(snapshot.observation(:cpu)).to be_complete
  end

  it "collects NTP once while separating current synchronization from successful statistics collection" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "/stats/sys/ntp" ]).once.and_return(response("/stats/sys/ntp", fixture("ntp")))
    snapshot = CtxChecker::Collector.new.collect_session(target: target, session: session, dimensions: %i[ntp device_counters])
    expect(snapshot.observation(:ntp).status).to eq(:partial)
    expect(snapshot.observation(:ntp).records.first[:synchronized]).to be_nil
    expect(snapshot.observation(:device_counters)).to be_complete
    expect(snapshot.observation(:device_counters).records).to all(include(discontinuity: nil))
  end

  it "discovers complete physical ports when a separate logical-interface query fails" do
    physical = parser.parse(:interfaces, two_port_link, complete: true, command: "/info/link")
    logical = parser.parse(:interfaces, fixture("command_error"), complete: true, command: "/info/l3/ip")
    observation = parser.combine(:interfaces, [ physical, logical ])
    expect(observation.status).to eq(:partial)
    expanded = parser.expand({ interfaces: observation }, dimensions: [ :counters ])
    expect(expanded.profile.commands_for(:counters)).to eq([ "/stats/port 27/if", "/stats/port 27/ether",
      "/stats/port 28/if", "/stats/port 28/ether" ])
  end

  it "never discovers ports from complete records without their complete physical command evidence" do
    observation = CtxChecker::Observation.new(name: :interfaces, status: :complete,
      records: [ { name: "port27", kind: :physical, source_complete: true } ],
      evidence: [ { command: "/info/l3/ip", status: :complete } ])
    expect(parser.expand({ interfaces: observation }, dimensions: [ :counters ]).profile.commands).not_to have_key(:counters)
  end

  it "enables transceiver queries only for exact firmware versions on documented fixed release lines" do
    base = CtxChecker::RadwareAlteon::Profile.new
    %w[30.5.9.0 30.5.10.0 31.0.6.0 31.0.20.0 32.1.0.0 32.4.15.0 32.4.20.0].each do |version|
      configured = base.with_software_version(version)
      expect(configured.commands_for(:optics)).to eq([ "/info/transceiver" ])
      expect(base.commands).not_to have_key(:optics)
    end
    [ nil, "", "30.5.8.99", "31.0.5.99", "32.0.99.0", "29.0.0.0", "33.0.0.0", "99.0.0.0",
      "32.4.15", "32.4.15.0-dev", "32.4.15.0\n", " 32.4.15.0", "032.4.15.0" ].each do |version|
      expect(base.with_software_version(version).commands).not_to have_key(:optics)
    end
    safe = base.with_software_version("32.4.15.0")
    expect(safe.with_software_version(nil).commands).not_to have_key(:optics)
    expect(safe.commands).to have_key(:optics)
  end

  it "preserves supplied firmware as a target fact and uses it before optical collection" do
    version = "32.4.15.0"
    configured_target = target.merge(software_version: version)
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "/info/transceiver" ]).once.and_return(response("/info/transceiver", fixture("transceiver_5424_32415")))
    snapshot = CtxChecker::Collector.new.collect_session(target: configured_target, session: session, dimensions: [ :optics ])
    expect(snapshot.target[:software_version]).to eq(version)
    expect(snapshot.target[:software_version]).to be_frozen
    expect(snapshot.observation(:optics).evidence.first[:command]).to eq("/info/transceiver")
    expect(snapshot.observation(:optics).records.size).to eq(56)
    expect(CtxChecker::RuntimeParser.new(platform: :h3c, software_version: "unrelated syntax").platform).to eq("h3c")
    expect do
      CtxChecker::RuntimeParser.new(platform: :radware, software_version: 32)
    end.to raise_error(ArgumentError, /Software version/)
  end

  it "does not send optics when firmware is unknown or belongs to a vulnerable release" do
    session = double(:session, connected?: true)
    expect(session).not_to receive(:send_commands)
    [ nil, "31.0.5.0" ].each do |version|
      snapshot = CtxChecker::Collector.new.collect_session(target: target.merge(software_version: version), session: session, dimensions: [ :optics ])
      expect(snapshot.observation(:optics).status).to eq(:unsupported)
    end
  end

  it "rejects untyped or control-bearing firmware facts before opening a connection" do
    connector = double(:connector)
    expect(connector).not_to receive(:open)
    [ 32, true, [ "32.4.15.0" ], "32.4.15.0\nforged" ].each do |version|
      expect do
        CtxChecker::Collector.new.collect(target: target.merge(software_version: version), connector: connector, dimensions: [ :optics ])
      end.to raise_error(ArgumentError, /target identity/)
      expect do
        CtxChecker::Snapshot.new(target: target.merge(software_version: version), observed_at: Time.now, observations: {})
      end.to raise_error(ArgumentError, /target/i)
    end
  end

  it "copies firmware facts without freezing caller data or treating firmware as counter continuity" do
    version = String.new("32.4.15.0")
    snapshot = CtxChecker::Snapshot.new(target: target.merge(software_version: version), observed_at: Time.now, observations: {})
    version.replace("32.4.20.0")
    expect(snapshot.target[:software_version]).to eq("32.4.15.0")
    expect(snapshot.to_h.fetch(:target).fetch(:software_version)).to eq("32.4.15.0")
    expect(snapshot.observation(:counters).records).to be_empty
  end

  it "keeps firmware-qualified optics independent from the full counter discovery budget" do
    configured = CtxChecker::RuntimeParser.new(platform: :radware, software_version: "32.4.15.0")
    expanded = configured.expand({ interfaces: inventory((1..256).map { |port| "port#{port}" }) }, dimensions: %i[counters optics])
    expect(expanded.profile.commands_for(:counters).size).to eq(512)
    expect(expanded.profile.commands_for(:optics)).to eq([ "/info/transceiver" ])
    expect(configured.profile.commands).not_to have_key(:counters)
  end
end
