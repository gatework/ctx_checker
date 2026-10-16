# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 区分可能重叠的累计指标；仅在采样连续性得到证明时计算增量。
    class Counters < Base
      # 按稳定计数器身份索引前次采样，使比较保持线性复杂度。
      def initialize(**options)
        super
        @previous_counters = @previous&.observation(dimension)
        @previous_records = @previous_counters&.records&.to_h { |row| [ row.values_at(*identity_fields), row ] } || {}
      end

      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        entity = record.slice(*identity_fields)
        value = record[:value]
        return finding(:unknown, :counter_unavailable, entity: entity) if value.nil?
        previous = @previous_counters
        prior = @previous_records[record.values_at(*identity_fields)]
        if (reason = packet_semantics_reason(record, prior))
          return finding(:unknown, reason, entity: entity, actual: record.slice(:value, :unit, :scope))
        end
        unless prior
          # 单次非零累计值无法证明当前窗口新增错误，等待可比较的前次采样。
          return finding(value.zero? ? :pass : :unknown, value.zero? ? :zero_cumulative_counter : :cumulative_errors,
            entity: entity, actual: value, severity: value.zero? ? :info : :warning)
        end
        interval = sample_time(record, @observation, @snapshot) - sample_time(prior, previous, @previous)
        # 先验证时间与重置标记；数值下降可能是清零或重启，不能按负增量计算。
        reason = if interval <= 0
          :counter_sample_time_invalid
        elsif record[:discontinuity].nil? || prior[:discontinuity].nil?
          :counter_continuity_unconfirmed
        elsif record[:discontinuity] != prior[:discontinuity] || prior[:value].nil? || value < prior[:value]
          :counter_discontinuity
        end
        return finding(:unknown, reason, entity: entity, actual: value, severity: :warning) if reason

        delta = value - prior[:value]
        limit = limit_for(record)
        # 超限是已观察故障；未超限仍需前后来源完整才能证明通过。
        if delta <= limit && (!record_complete?(prior, previous) || !record_complete?(record, @observation))
          return finding(:unknown, :counter_evidence_incomplete, entity: entity, actual: { delta: delta, seconds: interval })
        end
        finding(delta > limit ? :fail : :pass, :counter_delta, entity: entity,
          actual: delta_measurement(value, delta, interval), expected: { maximum_delta: limit }, severity: :warning)
      end

      # 选择当前评估负责的观测维度。
      def dimension = :counters
      # 返回用于跨采样匹配记录的稳定身份字段。
      def identity_fields = Observation::IDENTITIES.fetch(dimension)
      # 优先使用资源专用阈值，再回退到策略默认值。
      def limit_for(record) = @policy.counter_limits.fetch(record[:metric], 0)
      # 将已计算增量与采样间隔组织为报告测量值。
      def delta_measurement(_value, delta, interval) = { delta: delta, seconds: interval }
      # 解析速率或增量分析所需的采样时间。
      def sample_time(record, observation, snapshot) = record[:sampled_at] ? Time.iso8601(record[:sampled_at]) : observation.observed_at || snapshot.observed_at

      # 包数阈值不能比较字节、事件计数，也不能比较测量语义已变化的采样。
      def packet_semantics_reason(record, prior)
        return unless dimension == :counters
        return :counter_unit_unknown if record[:unit] == :unknown
        return :counter_unit_not_packets unless record[:unit].nil? || record[:unit] == :packets
        return :counter_scope_unknown if record[:scope] == :unknown
        return unless prior
        return :counter_unit_changed if record[:unit] != prior[:unit]
        :counter_scope_changed if record[:scope] != prior[:scope]
      end
    end
  end
end
