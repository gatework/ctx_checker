# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 按作用域比较百分比，避免混用 CPU 时间窗、处理平面或内存池。
    class Resources < Base
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        entity = record.slice(:component, :scope, :window_seconds)
        results = []
        state = record[:status]
        if %i[warning critical failed].include?(state)
          results << finding(:fail, :memory_pressure_state, entity: entity, actual: state, severity: state == :warning ? :warning : :critical)
        end
        if @observation.name == :memory && !%i[used_total available used_minus_cache].include?(record[:basis])
          return results + [ finding(:unknown, :memory_basis_unavailable, entity: entity, actual: record) ]
        end
        if inconsistent?(record)
          return results + [ finding(:unknown, :resource_measurements_inconsistent, entity: entity, actual: record) ]
        end
        value = record[:utilization]
        return results + [ finding(:unknown, :resource_utilization_unavailable, entity: entity, actual: record) ] unless value

        limits = @policy.system.resource_thresholds.fetch(@observation.name)
        severity = if value >= limits[:critical]
          :critical
        elsif value >= limits[:warning]
          :warning
        else
          :info
        end
        results << finding(severity == :info ? :pass : :fail, :resource_utilization, entity: entity,
          actual: record, expected: limits, severity: severity)
        results
      end

      # 总量或中断子集数值不合理时，不能据此判定利用率健康。
      def inconsistent?(record)
        if @observation.name == :cpu
          record[:interrupt_utilization] && record[:utilization] && record[:interrupt_utilization] > record[:utilization]
        else
          return true if record[:status] == :absent
          total = record[:total_bytes]
          return false unless total
          return true if total.zero? || record.values_at(:used_bytes, :free_bytes, :available_bytes).compact.any? { |value| value > total }
          if record[:basis] == :used_total && record[:used_bytes] && record[:free_bytes]
            return true if record[:used_bytes] + record[:free_bytes] != total
          end
          if %i[available used_minus_cache].include?(record[:basis]) && record[:used_bytes] && record[:available_bytes]
            return true if record[:used_bytes] + record[:available_bytes] != total
          end
          used = record[:basis] == :available && record[:available_bytes] ? total - record[:available_bytes] : record[:used_bytes]
          return true if record[:basis] == :available && used && record[:used_bytes] && used != record[:used_bytes]
          used && record[:utilization] && (used.fdiv(total) * 100 - record[:utilization]).abs > 1
        end
      end
    end
  end
end
