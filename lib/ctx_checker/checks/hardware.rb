# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 区分可选空槽位、组件故障与策略明确要求的组件。
    class Hardware < Base
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        entity = record.slice(:component, :kind)
        state = record[:status]
        if record[:watts] && record[:capacity_watts] && record[:watts] > record[:capacity_watts]
          return [ finding(:fail, :power_capacity_exceeded, entity: entity,
            actual: record[:watts], expected: { maximum_watts: record[:capacity_watts] }, severity: :critical),
            finding(:unknown, :power_measurements_inconsistent, entity: entity, actual: record) ]
        end
        if %i[warning critical failed].include?(state)
          return finding(:fail, :hardware_fault, entity: entity, actual: record, severity: state == :warning ? :warning : :critical)
        end
        if record[:present] == false || state == :absent
          if state == :ok || record[:present] == true || record[:watts]&.positive?
            return finding(:unknown, :hardware_presence_inconsistent, entity: entity, actual: record)
          end
          required = required_components.include?(record[:component])
          return finding(required ? :fail : :not_applicable, :hardware_absent, entity: entity,
            actual: record, severity: required ? :critical : :info)
        end
        finding(state == :ok ? :pass : :unknown, :hardware_state, entity: entity, actual: record)
      end

      # 解析策略明确要求的环境组件。
      def required_components = @policy.system.required_components.fetch(@observation.name, [])

      # 为策略要求但未观察到的资源生成证据缺失结果。
      def missing
        (required_components - @observation.records.map { |row| row[:component] }).map do |component|
          finding(missing_status, :required_component_missing, entity: { component: component }, severity: :critical)
        end
      end
    end
  end
end
