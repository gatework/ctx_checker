# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 在所属 VRF、地址族或进程作用域中解释协议会话状态。
    class Routing < Base
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        identity = record.slice(*identity_fields)
        state = record[:state]
        status, reason = if state.nil? || state == :unknown
          [ :unknown, :protocol_state_unavailable ]
        elsif @observation.name == :bgp
          state == :established ? [ :pass, :bgp_established ] : [ :fail, :bgp_not_established ]
        elsif state == :full
          [ :pass, :ospf_full ]
        elsif state == :two_way
          two_way_state(record)
        else
          [ :fail, :ospf_not_adjacent ]
        end
        status, reason = :unknown, :protocol_scope_unavailable if status == :pass && identity.values.any?(&:nil?)
        finding(status, reason, entity: identity, actual: record, severity: status == :fail ? :critical : :info)
      end

      # 返回用于跨采样匹配记录的稳定身份字段。
      def identity_fields = @observation.name == :bgp ? %i[vrf afi_safi peer] : %i[vrf process_id interface router_id]

      # 仅在拓扑明确不要求建立邻接时，将 OSPF 2-Way 状态视为正常。
      def two_way_state(record)
        if %i[point_to_point point_to_multipoint virtual_link].include?(record[:network_type]) ||
            %i[dr bdr].include?(record[:local_role]) || %i[dr bdr].include?(record[:neighbor_role])
          [ :fail, :ospf_expected_adjacency_missing ]
        elsif %i[broadcast nbma].include?(record[:network_type]) && record[:local_role] == :drother && record[:neighbor_role] == :drother
          [ :pass, :ospf_expected_two_way ]
        else
          [ :unknown, :ospf_two_way_requires_topology ]
        end
      end

      # 为策略要求但未观察到的资源生成证据缺失结果。
      def missing
        expected = @observation.name == :bgp ? @policy.expected_bgp : @policy.expected_ospf
        if expected.empty?
          reason = @observation.issues.map { |issue| issue[:code] }.find { |code| %i[protocol_not_configured protocol_disabled].include?(code) }
          return [] unless @observation.records.empty? && reason

          return [ finding(:unknown, reason) ]
        end

        fields = identity_fields
        scope = @observation.name == :bgp ? %i[vrf afi_safi] : %i[vrf process_id interface]
        identities = {}
        scopes = {}
        incomplete = Hash.new { |hash, keys| hash[keys] = {} }
        @observation.records.each do |record|
          identities[record.values_at(*fields)] = true
          scopes[record.values_at(*scope)] = true
          present = fields.reject { |key| record[key].nil? }
          incomplete[present][record.values_at(*present)] = true unless present == fields
        end
        expected.filter_map do |identity|
          next if identities.key?(identity.values_at(*fields))

          ambiguous = incomplete.any? { |keys, values| values.key?(identity.values_at(*keys)) }
          enumerated = @observation.covered_scopes.any? { |entry| entry.all? { |key, value| identity[key] == value } }
          scope_observed = scopes.key?(identity.values_at(*scope))
          status = if ambiguous
            :unknown
          elsif enumerated
            :fail
          elsif scope_observed
            missing_status
          else
            :unknown
          end
          finding(status, :expected_peer_missing, entity: identity, severity: :critical)
        end
      end
    end
  end
end
