# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 当前告警独立于历史事件日志进行评估。
    class Alarms < Base
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        entity = record.slice(:component, :alarm_id)
        active = record[:active]
        if active.nil? || active == false && record[:count]&.positive? || active == true && record[:count] == 0
          return finding(:unknown, :alarm_state_unavailable, entity: entity, actual: record)
        end
        return finding(:pass, :alarm_clear, entity: entity, actual: record) unless active
        return finding(:not_applicable, :informational_alarm, entity: entity, actual: record) if record[:severity] == :info

        finding(:fail, :active_alarm, entity: entity, actual: record, severity: record[:severity] == :critical ? :critical : :warning)
      end
    end
  end
end
