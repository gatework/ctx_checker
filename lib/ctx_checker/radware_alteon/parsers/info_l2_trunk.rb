# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # trunk 成员关系与 STP 转发状态不能独立证明链路状态。
      class InfoL2Trunk < CtxChecker::Parsers::Base
        GROUP = /\ATrunk group (\d+), bw contract \d+, name:.*?, port state:\z/i
        MEMBER = /\A(\d+):\s+STG\s+\d+\s+(\S+)\z/i

        private

        # 将成员限定在其所属 trunk 中，明确保留不完整聚合组。
        def parse_output(text, complete:)
          rows, issues, groups, current = [], [], [], nil
          clean(text).each_line do |raw|
            line = raw.strip
            next if line.empty? || /\A-+\z/.match?(line)

            if (match = GROUP.match(line)) && match[1].to_i.positive?
              current = "trunk#{Integer(match[1], 10)}"
              issues << { code: :duplicate_aggregation_header, group: current } if groups.include?(current)
              groups << current
            elsif current && (match = MEMBER.match(line)) && match[1].to_i.positive?
              member = "port#{Integer(match[1], 10)}"
              state = match[2].downcase
              issues << { code: :aggregation_forwarding_state_unknown, group: current, interface: member } unless state == "forwarding"
              rows << { group: current, member: member,
                member_status: state == "forwarding" ? :active : :unknown, oper_status: :unknown }
            else
              current = nil
              issues << { code: :unrecognized_aggregation_line }
            end
          end
          (groups.uniq - rows.map { |row| row[:group] }).each do |group|
            rows << { group: group, member: nil, member_status: :unknown, oper_status: :unknown }
            issues << { code: :aggregation_members_unavailable, group: group }
          end
          build_result(rows, complete: complete, recognized: groups.any?, issues: issues, identity: %i[group member])
        end
      end
    end
  end
end
