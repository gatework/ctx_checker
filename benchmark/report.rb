# frozen_string_literal: true

require_relative "../lib/ctx_checker"

# 合成端口查询失败，只测报告构建，不包含网络、解析及夹具生成耗时。
[ 64, 256, 512 ].each do |size|
  commands = Array.new(size) { |index| "read port #{index + 1}" }
  observation = CtxChecker::Observation.new(name: :counters, status: :failed,
    evidence: commands.map { |command| { command: command, status: :failed } },
    issues: commands.map { |command| { command: command, code: :command_failed } })
  snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "radware_alteon" },
    observed_at: Time.utc(2026, 10, 18), observations: { counters: observation })
  build = -> { CtxChecker::Report.new(snapshot: snapshot, findings: []) }
  result = build.call
  abort "Command outcomes changed" unless result.commands.map { |entry| entry[:command] } == commands &&
    result.commands.all? { |entry| entry[:status] == :failed && entry[:issues].one? && entry[:issues].first[:command] == entry[:command] }
  5.times { build.call }
  GC.start
  allocated = GC.stat(:total_allocated_objects)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  30.times { build.call }
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  allocations = GC.stat(:total_allocated_objects) - allocated
  puts format("commands=%d ms/report=%.3f objects/report=%d", size, elapsed * 1000 / 30, allocations / 30)
end
