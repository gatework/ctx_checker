# frozen_string_literal: true

require "ctx_checker"
require "ctx_parser"
require "ctx_driver"
require "json"

# 合成配置和回显贯通三个模块；不包含网络、输入生成或策略构造耗时。
PipelineReceipt = Data.define(:output, :body, :steps) do
  def success? = true
  def value! = body
end

class PipelineSession
  attr_reader :queries

  def initialize(receipt)
    @receipt = receipt
    @queries = 0
  end

  def connected? = true

  def send_commands(commands)
    raise "Unexpected query" unless commands == [ "show interfaces" ]

    @queries += 1
    @receipt
  end
end

def measure
  samples = 3.times.map do
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    value = yield
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    [ value, { milliseconds: (elapsed * 1000).round(3), allocations: GC.stat(:total_allocated_objects) - allocated } ]
  end
  samples.sort_by { |_, stats| stats[:milliseconds] }[1]
end

puts RUBY_DESCRIPTION
puts JSON.generate(sources: [ CtxParser::Input.method(:text), CtxDriver::Reader.instance_method(:read),
  CtxChecker::RuntimeParser.instance_method(:parse_many), CtxParser::Immutable.method(:copy),
  CtxChecker::Observation.instance_method(:initialize) ].map { |method| method.source_location.first })

[ 100, 1000, 5000 ].each do |size|
  names = Array.new(size) { |index| "GigabitEthernet1/0/#{index + 1}" }
  config = "hostname bench\n" + names.map { |name| "interface #{name}\n description benchmark\n!\n" }.join("") + "end\n"
  body = names.map do |name|
    "#{name} is up, line protocol is up\n  0 input errors, 0 CRC\n  0 output errors\n"
  end.join("").freeze
  receipt = PipelineReceipt.new(output: "show interfaces\n#{body}device#".freeze, body: body, steps: [ { command: "show interfaces" } ].freeze)
  time = Time.utc(2026, 10, 21).freeze
  session = PipelineSession.new(receipt)
  collector = CtxChecker::Collector.new(clock: -> { time })
  target = { host: "192.0.2.1", platform: "cisco_ios" }.freeze
  evaluator = CtxChecker::Evaluator.new(policy: CtxChecker::Policy.new(required_interfaces: names))
  applicability, configuration = measure do
    CtxChecker::Applicability.from_configuration(platform: :cisco_ios, text: config, complete: true)
  end
  snapshot, collection = measure do
    collector.collect_session(target: target, session: session, dimensions: %i[interfaces counters bgp], applicability: applicability)
  end
  report, evaluation = measure { evaluator.call(snapshot) }
  raise "Shared query repeated" unless session.queries == 3
  raise "Lost interfaces" unless snapshot.observation(:interfaces).records.size == size
  raise "Lost counters" unless snapshot.observation(:counters).records.size == size * 3
  raise "Incorrect health" unless report.healthy? && report.counts[:pass] == size * 4
  raise "Configuration evidence lost" unless snapshot.observation(:bgp).status == :not_applicable

  puts JSON.generate(interfaces: size, configuration_bytes: config.bytesize, body_bytes: body.bytesize,
    configuration: configuration, collection: collection, evaluation: evaluation)
end
