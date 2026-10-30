# frozen_string_literal: true

require "ctx_checker"

# 同一批合成 VRF 分别测缺失邻居评估和冲突来源归并，不含输入构造耗时。
def measure
  3.times.map do
    GC.start
    allocated = GC.stat(:total_allocated_objects)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    { ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000,
      objects: GC.stat(:total_allocated_objects) - allocated }
  end.min_by { |sample| sample[:ms] }
end

[ 500, 1000, 2000 ].each do |size|
  scopes = Array.new(size) { |index| { vrf: "v#{index}", afi_safi: "ipv4_unicast" } }
  peers = scopes.map { |scope| scope.merge(peer_address: "192.0.2.1") }
  observation = CtxChecker::Observation.new(name: :bgp, status: :complete, covered_scopes: scopes)
  snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "cisco_ios" },
    observed_at: Time.utc(2026, 10, 18), observations: { bgp: observation })
  evaluator = CtxChecker::Evaluator.new(policy: CtxChecker::Policy.new(expected_bgp: peers))
  routing = measure do
    report = evaluator.call(snapshot)
    raise "Missing peer findings changed" unless report.counts[:fail] == size
  end
  rows = peers.map { |peer| peer.merge(state: :established) }
  observations = 2.times.map do |index|
    CtxChecker::Observation.new(name: :bgp, status: :complete, covered_scopes: scopes,
      records: rows, evidence: [ { command: "read#{index}" } ])
  end
  merging = measure do
    result = CtxChecker::ObservationMerger.call(:bgp, observations, commands: %w[read0 read1])
    raise "Conflicting scope findings changed" unless result.records.empty? && result.covered_scopes.empty? && result.status == :partial
  end
  puts format("scopes=%d routing_ms=%.3f routing_objects=%d merge_ms=%.3f merge_objects=%d",
    size, routing[:ms], routing[:objects], merging[:ms], merging[:objects])
end
