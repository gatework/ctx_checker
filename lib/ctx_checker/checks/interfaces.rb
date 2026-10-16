# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 评估物理与逻辑链路，同时尊重明确的管理关闭意图。
    class Interfaces < Base
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        name = record[:name]
        required = @policy.required_interfaces.include?(name)
        status, reason = if record[:admin_status] == :down && !required
          [ :not_applicable, :administratively_down ]
        elsif record[:oper_status] == :down || record[:protocol_status] == :down && record[:protocol_applicable] != false || required && record[:admin_status] == :down
          [ :fail, :interface_down ]
        elsif record[:oper_status] == :up && (record[:protocol_applicable] == false || record[:protocol_status] == :up || %i[physical aggregate].include?(record[:kind]))
          [ :pass, :interface_up ]
        else
          [ :unknown, :interface_state_unavailable ]
        end
        finding(status, reason, entity: name, actual: record, severity: required ? :critical : :warning)
      end

      # 为策略要求但未观察到的资源生成证据缺失结果。
      def missing
        (@policy.required_interfaces - @observation.records.map { |row| row[:name] }).map do |name|
          finding(missing_status, :required_interface_missing, entity: name, severity: :critical)
        end
      end
    end
  end
end
