# frozen_string_literal: true

require_relative "policy"
require_relative "report"
require_relative "checks/interfaces"
require_relative "checks/counters"
require_relative "checks/aggregation"
require_relative "checks/optics"
require_relative "checks/routing"
require_relative "checks/resources"
require_relative "checks/temperature"
require_relative "checks/hardware"
require_relative "checks/clock"
require_relative "checks/ntp"
require_relative "checks/alarms"
require_relative "checks/device_counters"

module CtxChecker
  # 基于不可变当前采样及可选的前次采样，组合厂商无关的检查。
  class Evaluator
    CHECKS = { interfaces: Checks::Interfaces, counters: Checks::Counters, aggregation: Checks::Aggregation,
      optics: Checks::Optics, bgp: Checks::Routing, ospf: Checks::Routing,
      cpu: Checks::Resources, memory: Checks::Resources, temperature: Checks::Temperature,
      environment: Checks::Hardware, power: Checks::Hardware, clock: Checks::Clock,
      ntp: Checks::Ntp, alarms: Checks::Alarms, device_counters: Checks::DeviceCounters }.freeze

    # 绑定归一化证据评估使用的策略。
    def initialize(policy: Policy.new)
      raise ArgumentError, "Evaluator requires a Policy" unless policy.is_a?(Policy)
      @policy = policy
      freeze
    end

    # 评估所有适用检查，分别返回健康结果与证据覆盖率。
    def call(snapshot, previous: nil)
      raise ArgumentError, "Evaluator requires a Snapshot" unless snapshot.is_a?(Snapshot)
      if previous && (!snapshot.same_target?(previous) || previous.observed_at >= snapshot.observed_at)
        raise ArgumentError, "Previous sample must belong to the same target and precede the current sample"
      end
      findings = CHECKS.flat_map do |name, checker|
        checker.new(snapshot: snapshot, policy: @policy, previous: previous).call(snapshot.observation(name))
      end
      snapshot.issues.each do |issue|
        findings << Finding.new(id: "collection.#{issue[:code]}", dimension: :collection, status: :unknown, reason: issue[:code].to_sym)
      end
      Report.new(snapshot: snapshot, findings: findings)
    end
  end
end
