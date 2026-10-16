# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 设备可达或已配置对等体不能代替系统同步证据。
    class Ntp < Base
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        entity = { component: record[:component] }
        return peer_attempt(record, entity) unless record[:component] == "system"

        unsynchronized = record[:synchronized] == false || record[:stratum] == 16 || record[:leap] == 3
        status = unsynchronized ? :fail : record[:synchronized] == true && record[:stratum] != 0 ? :pass : :unknown
        results = [ finding(status,
          :ntp_synchronization, entity: entity, actual: record, severity: unsynchronized ? :warning : :info) ]
        if record[:synchronized] == true && (unsynchronized || record[:stratum] == 0)
          results << finding(:unknown, :ntp_state_inconsistent, entity: entity)
        end
        if record[:offset_ms]
          exceeded = record[:offset_ms].abs > @policy.system.max_ntp_offset_ms
          results << finding(exceeded ? :fail : :pass, :ntp_offset, entity: entity, actual: record[:offset_ms],
            expected: { maximum_absolute_ms: @policy.system.max_ntp_offset_ms }, severity: exceeded ? :warning : :info)
        end
        results
      end

      # 可独立报告对等体尝试失败，但不能据此断言系统已失去同步。
      def peer_attempt(record, entity)
        if record[:last_sync_status] == :failed
          finding(:fail, :ntp_last_sync_failed, entity: entity, actual: record, severity: :warning)
        else
          finding(:not_applicable, :ntp_peer_context, entity: entity, actual: record)
        end
      end

      # 为策略要求但未观察到的资源生成证据缺失结果。
      def missing
        return [] if @observation.records.any? { |row| row[:component] == "system" }
        [ finding(:unknown, :ntp_system_state_unavailable) ]
      end
    end
  end
end
