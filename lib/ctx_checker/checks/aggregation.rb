# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 逐个评估成员；即使聚合接口仍为 up，也保留成员故障。
    class Aggregation < Base
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        record = resolved_state(record)
        if record[:member].nil?
          return finding(record[:oper_status] == :down ? :fail : :unknown, :aggregation_members_unavailable,
            entity: record[:group], actual: record, severity: :warning)
        end
        status, reason = if record[:oper_status] == :down || member_down?(record) || %i[down suspended unselected].include?(record[:member_status])
          [ :fail, :aggregation_member_down ]
        elsif %i[active standby].include?(record[:member_status]) && record[:oper_status] == :up
          [ :pass, record[:member_status] == :standby ? :aggregation_standby : :aggregation_active ]
        else
          [ :unknown, :aggregation_state_unavailable ]
        end
        finding(status, reason, entity: record.slice(:group, :member), actual: record, severity: :warning)
      end

      # 为策略要求但未观察到的资源生成证据缺失结果。
      def missing
        rows = @observation.records.map { |record| resolved_state(record) }.group_by { |record| record[:group] }
        results = @policy.required_members.flat_map do |group, members|
          group_rows = rows.fetch(group, [])
          status = group_rows.any? { |row| row[:member].nil? } ? :unknown : missing_status
          (members - group_rows.map { |row| row[:member] }).map do |member|
            finding(status, :required_member_missing, entity: { group: group, member: member }, severity: :critical)
          end
        end
        @policy.minimum_active_members.each do |group, minimum|
          group_rows = rows.fetch(group, [])
          members = group_rows.reject { |row| row[:member].nil? }
          # 容量下界只计入完整来源；不完整成员也不能证明容量不足。
          active_members = members.select { |row| record_complete?(row, @observation) && row[:member_status] == :active && row[:oper_status] == :up && !member_down?(row) }
          active = active_members.size
          known = group_rows.none? { |row| row[:member].nil? } && members.all? do |row|
            record_complete?(row, @observation) && row[:member_status] && row[:member_status] != :unknown && %i[up down].include?(row[:oper_status])
          end
          status = if active >= minimum
            :pass
          elsif @observation.complete? && known
            :fail
          else
            :unknown
          end
          results << finding(status, :aggregation_capacity, entity: group, actual: active, expected: minimum, severity: :critical, sources: active_members)
        end
        results
      end

      # Comware 成员表不提供链路状态；仅关联完整的父级接口证据。
      def resolved_state(record)
        return record if %i[up down].include?(record[:oper_status])

        parent = interface(record[:group])
        return record unless parent && parent[:kind] == :aggregate &&
          record_complete?(parent, @snapshot.observation(:interfaces))

        record.merge(oper_status: parent[:oper_status])
      end

      # 成员处于选中状态，不能覆盖已确认的物理链路故障。
      def member_down?(record)
        physical = interface(record[:member])
        physical && record_complete?(physical, @snapshot.observation(:interfaces)) && physical[:oper_status] == :down
      end
    end
  end
end
