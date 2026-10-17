# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module H3c
    module Parsers
      # 本地成员选中状态不能从远端 LACP 记录推断。
      class DisplayLinkAggregationVerbose < CtxChecker::Parsers::Base
        GROUP = /\A(?:Bridge-Aggregation|Route-Aggregation|BAGG|RAGG)\d+\z/i
        LOCAL_HEADER = /\APort\s+Status\s+Priority(?:\s+(Index))?\s+Oper-Key(?:\s+(Flag))?\z/i
        MEMBER = /\A([A-Za-z][A-Za-z-]*\d+(?:[\/.]\d+)*)(?:\(([AMR])\))?\s+([SUI])\s+(\d+)\s+(\d+)(?:\s+(\d+))?(?:\s+(\{[A-H]*\}))?\z/
        METADATA = /\A(?:-+|Loadsharing Type:|Port Status:|Port:|Flags:|[A-H] --|Creation Mode:|Aggregation Mode:|System ID:)/

        private

        # 按聚合组及声明的列布局限定各本地表的作用域。
        def parse_output(text, complete:)
          text = clean(text)
          if /\AInfo:\s+No link aggregation group defined at present\.\z/i.match?(text.strip)
            return build_result([], complete: complete, recognized: true, issues: [ { code: :aggregation_not_configured } ])
          end
          rows, issues, group, remote, groups, columns, tables = [], diagnostics, nil, false, {}, nil, []
          text.each_line do |raw|
            line = raw.strip
            if (match = /\AAggregate Interface:\s*(.*)\z/i.match(line))
              group, remote, columns = nil, false, nil
              if GROUP.match?(match[1])
                group = CtxChecker::Parsers::InterfaceNames.normalize(match[1], platform: :h3c)
                issues << { code: :duplicate_aggregation_group, group: group } if groups.key?(group)
                groups[group] ||= 0
              else
                issues << { code: :invalid_aggregation_group }
              end
            elsif line == "Remote:"
              remote = true
              columns = nil
            elsif line == "Local:"
              remote = false
              columns = nil
            elsif !remote && (match = LOCAL_HEADER.match(line))
              columns = { indexed: !match[1].nil?, flags: !match[2].nil?, group: group, count: 0 }
              tables << columns
            elsif !remote && (record = local_member(line, group: group, columns: columns))
              rows << record
              groups[group] += 1
              columns[:count] += 1
            elsif !remote && line.match?(/\A[A-Za-z][A-Za-z-]*\d+(?:[\/.]\d+)*(?:\([^\s]*\))?\s/)
              issues << { code: :invalid_aggregation_member }
            elsif !remote && !line.empty? && !METADATA.match?(line) && !/\AManagement VLANs:\s*(?:None|\d+(?:-\d+)?(?:,\s*\d+(?:-\d+)?)*)\z/i.match?(line)
              issues << { code: :unrecognized_aggregation_line }
            end
          end
          groups.each { |name, count| issues << { code: :aggregation_members_missing, group: name } if count.zero? }
          tables.each { |table| issues << { code: :aggregation_members_missing, group: table[:group] } if table[:count].zero? }
          build_result(rows, complete: complete, recognized: groups.any?, issues: issues, identity: %i[group member])
        end

        # 仅在身份匹配前移除已知端口角色标记，不修改状态文本。
        def local_member(line, group:, columns:)
          return unless group && columns
          match = MEMBER.match(line)
          return unless match && columns[:indexed] == !match[6].nil? && columns[:flags] == !match[7].nil?

          { group: group, member: CtxChecker::Parsers::InterfaceNames.normalize(match[1], platform: :h3c),
            member_status: { "S" => :active, "U" => :unselected, "I" => :unselected }.fetch(match[3]), oper_status: :unknown }
        end
      end
    end
  end
end
