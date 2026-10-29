# frozen_string_literal: true

require_relative "spec_helper"
require "net/connector"
require "ctx_checker"

RSpec.describe "Hillstone runtime integration" do
  let(:target) { { host: "192.0.2.203", platform: "hillstone", model: "SG-6000-A3700" } }
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :stoneos, model: target[:model]) }

  # 通过与实时采集相同的边界重放脱敏命令正文。
  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/hillstone/#{name}.txt", __dir__))
  end

  # 传输成功的响应仍可能包含不支持的 CLI 语法。
  def response(body, command: "show interfaces")
    command_receipt(body, command: command, output: "command\n#{body}device#")
  end

  it "resolves StoneOS and shares each query across its declared dimensions" do
    expect(parser.platform).to eq("hillstone")
    queries = parser.queries(CtxChecker::RuntimeParser::DIMENSIONS)
    expect(queries.fetch("show interface")).to eq(%i[interfaces aggregation])
    expect(queries.fetch("show environment")).to eq(%i[temperature environment power])
    expect(queries.fetch("show interface counter")).to eq([ :counters ])
    expect(queries.fetch("show ntp status")).to eq([ :ntp ])
    expect(parser.profile.commands).not_to have_key(:alarms)
    expect(queries.keys).to all(match(/\Ashow [a-z -]+\z/))
  end

  it "keeps transparent links up and treats real link-down ports independently" do
    observations = parser.parse_many(%i[interfaces aggregation], fixture("interfaces_live"), complete: true)
    snapshot = CtxChecker::Snapshot.new(target: target, observed_at: Time.utc(2026, 10, 16), observations: observations)
    results = CtxChecker::Evaluator.new.call(snapshot).findings.select { |finding| finding.dimension == :interfaces }
    by_name = results.to_h { |finding| [ finding.entity, finding ] }
    %w[ha0 mgt0 vswitchif1 ethernet0/0 xethernet0/24 xethernet0/25].each do |name|
      expect(by_name.fetch(name).status).to eq(:pass)
    end
    expect(by_name.fetch("ethernet0/1").status).to eq(:fail)
    expect(observations.fetch(:aggregation).records).to be_empty
  end

  it "preserves online discards while marking absent CRC and error metrics unavailable" do
    observation = parser.parse_outputs(:counters, { "show interface counter" => fixture("interface_counters_live") }, complete: true)
    expect(observation.status).to eq(:partial)
    expect(observation.records.size).to eq(25)
    expect(observation.records).to include(include(interface: "mgt0", metric: :crc_errors, value: nil))
    expect(observation.records).not_to include(include(interface: "ethernet0/1"))
    snapshot = CtxChecker::Snapshot.new(target: target, observed_at: Time.utc(2026, 10, 16), observations: { counters: observation })
    report = CtxChecker::Evaluator.new.call(snapshot)
    expect(report).not_to be_complete
    expect(report.findings).to include(have_attributes(status: :pass, reason: :zero_cumulative_counter,
      entity: { interface: "xethernet0/25", metric: :out_discards }))
    expect(report.findings).to include(have_attributes(status: :unknown, reason: :counter_unavailable,
      entity: { interface: "xethernet0/25", metric: :crc_errors }))
  end

  it "continues after a rejected script and collects a shared hardware query only once" do
    session = double(:session, connected?: true)
    expect(session).to receive(:send_commands).with([ "show cpu" ]).ordered.and_return(response(" ^-----unrecognized keyword cpu\n", command: "show cpu"))
    expect(session).to receive(:send_commands).with([ "show memory" ]).ordered.and_return(response(fixture("memory_a3700_55r10p14"), command: "show memory"))
    expect(session).to receive(:send_commands).with([ "show environment" ]).once.ordered.and_return(response(fixture("environment_a3700_55r10p14"), command: "show environment"))
    snapshot = CtxChecker::Collector.new.collect_session(target: target, session: session,
      dimensions: %i[cpu memory temperature environment power alarms])
    expect(snapshot.observation(:cpu).status).to eq(:unsupported)
    %i[memory temperature environment power].each do |name|
      expect(snapshot.observation(name).status).to eq(:complete)
    end
    expect(snapshot.observation(:temperature).evidence).to eq(snapshot.observation(:power).evidence)
    expect(snapshot.observation(:alarms).status).to eq(:unsupported)
  end
end
