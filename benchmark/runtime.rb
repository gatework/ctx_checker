# frozen_string_literal: true

require "ctx_checker"
require "json"

# 合成输入只测本地解析开销，不连接设备，也不代表网络吞吐。
def measure
  GC.start
  allocations = GC.stat(:total_allocated_objects)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  [ result, { milliseconds: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(3),
    allocations: GC.stat(:total_allocated_objects) - allocations } ]
end

[ 16, 64, 256 ].each do |ports|
  parser = CtxChecker::RuntimeParser.new(platform: :radware_alteon)
  observation = CtxChecker::Observation.new(name: :interfaces, status: :complete,
    records: (1..ports).map { |port| { name: "port#{port}", kind: :physical, source_complete: true } },
    evidence: [ { command: "/info/link", status: :complete } ])
  parser, preparation = measure { parser.expand({ interfaces: observation }, dimensions: [ :counters ]) }
  commands = parser.profile.commands_for(:counters)
  samples = 3.times.map do
    measure { commands.each { |command| parser.parse(:counters, "", complete: true, command: command) } }.last
  end
  puts JSON.generate(case: "command_lookup", ports: ports, commands: commands.size, preparation: preparation,
    best: samples.min_by { |sample| sample[:milliseconds] })
end

parser = CtxChecker::RuntimeParser.new(platform: :cisco_ios)
body = "Error:\n" * 149_796
observation, stats = measure { parser.parse(:clock, body, complete: true) }
puts JSON.generate(case: "command_errors", bytes: body.bytesize, status: observation.status, issues: observation.issues.size, **stats)
