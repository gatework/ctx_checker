# frozen_string_literal: true

require_relative "hardware"

module CtxChecker
  module Checks
    # 优先使用设备或精确传感器的摄氏度阈值，不虚构通用温度限制。
    class Temperature < Hardware
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        return super if record[:status] == :absent && record[:value].nil?
        entity = { component: record[:component] }
        override = @policy.system.temperature_thresholds[record[:component]]
        bounds = (override || record).slice(*Observation::OPTICAL_THRESHOLDS).compact
        comparison = override ? override.fetch(:high_comparison, :gt) : record[:high_comparison]
        state = record[:status]
        explicit_fault = %i[warning critical failed].include?(state)
        results = []
        results << finding(:unknown, :temperature_presence_inconsistent, entity: entity) if state == :absent
        results << finding(:fail, :temperature_alarm, entity: entity, actual: state, severity: state == :warning ? :warning : :critical) if explicit_fault
        unless bounds.values_at(*Observation::OPTICAL_THRESHOLDS).compact.each_cons(2).all? { |low, high| low <= high }
          return results + [ finding(:unknown, :temperature_thresholds_invalid, entity: entity) ]
        end
        value = record[:value]
        if value && bounds.any?
          severity = exceeded(value, bounds, comparison)
          boundary_unknown = comparison.nil? && bounds.values_at(:high_warning, :high_alarm).compact.include?(value)
          status = severity ? :fail : boundary_unknown || state == :absent ? :unknown : :pass
          results << finding(status, boundary_unknown && !severity ? :temperature_boundary_unknown : :temperature_threshold, entity: entity,
            actual: value, expected: bounds.merge(high_comparison: comparison), severity: severity || :info)
          if !override && (state == :ok && severity || explicit_fault && !severity)
            results << finding(:unknown, :temperature_state_disagreement, entity: entity)
          end
        elsif !explicit_fault
          results << finding(state == :ok ? :pass : :unknown, :temperature_state, entity: entity, actual: record)
        end
        results
      end

      # 为测量值超出阈值生成检查结果。
      def exceeded(value, bounds, comparison)
        return :critical if bounds[:low_alarm] && value < bounds[:low_alarm] || above?(value, bounds[:high_alarm], comparison)
        return :warning if bounds[:low_warning] && value < bounds[:low_warning] || above?(value, bounds[:high_warning], comparison)
        nil
      end

      # 将可用测量值与配置的上限比较。
      def above?(value, limit, comparison) = limit && (value > limit || comparison == :gte && value == limit)
    end
  end
end
