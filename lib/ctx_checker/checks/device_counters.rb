# frozen_string_literal: true

require_relative "counters"

module CtxChecker
  module Checks
    # 区分设备级指标；策略主动丢弃仅在运维明确配置阈值时评估。
    class DeviceCounters < Counters
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        unless @policy.system.device_counter_limits.key?(record[:metric])
          case record[:category]
          when :policy, :informational
            return finding(:not_applicable, :device_counter_context, entity: record.slice(*identity_fields), actual: record)
          when nil, :unknown
            return finding(:unknown, :counter_category_unavailable, entity: record.slice(*identity_fields), actual: record)
          end
        end
        super
      end

      # 选择当前评估负责的观测维度。
      def dimension = :device_counters
      # 优先使用资源专用阈值，再回退到策略默认值。
      def limit_for(record) = @policy.system.device_counter_limits.fetch(record[:metric], 0)
      # 组织累计量、已验证增量及采样间隔，并计算每秒速率。
      def delta_measurement(value, delta, interval) = { cumulative: value, delta: delta, seconds: interval, per_second: delta / interval }
    end
  end
end
