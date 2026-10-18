# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module PaloAlto
    module Parsers
      # PAN-OS LACP 回显中的成组关系与选中状态是独立事实。
      class ShowLacpAggregateEthernet < CtxChecker::Parsers::Base
        private

        # 解析 show lacp aggregate ethernet，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues, group, header, groups = [], diagnostics, nil, false, {}
          text.each_line("\n") do |raw|
            line = raw.strip
            if (match = /\AAE group:\s*(ae\d+)\z/i.match(line))
              group = match[1].downcase
              groups[group] ||= 0
            elsif line.match?(/\AMembers:\s+Bndl\s+Rx state\s+Mux state\s+Sel state\z/i)
              header = true
            elsif (match = /\A(ethernet\d+\/\d+)\s+(yes|no)\s+(\S+)\s+(\S+)\s+(Selected|Unselected|Standby)(?:\(.*\))?\z/i.match(line))
              if group
                state = if match[5].casecmp?("Standby")
                  :standby
                elsif match[5].casecmp?("Unselected")
                  :unselected
                elsif match[2].casecmp?("yes") && match[4].casecmp?("Tx_Rx")
                  :active
                else
                  :unknown
                end
                rows << { group: group, member: match[1].downcase, member_status: state, oper_status: :unknown }
                groups[group] += 1
              else
                issues << { code: :aggregation_group_missing }
              end
            elsif line.match?(/\Aethernet\d+\//i)
              issues << { code: :invalid_aggregation_member }
            elsif !line.empty? && !line.match?(/\A(?:\*+|-+|LACP:|Status:|Mode:|Rate:|Max-port:|Fast-failover:|Pre-negotiation:|Local:|Partner:|System Priority:|System MAC:|Key:)/i)
              issues << { code: :unrecognized_aggregation_line }
            end
          end
          groups.each { |name, count| issues << { code: :aggregation_members_missing, group: name } if count.zero? }
          build_result(rows, complete: complete, recognized: header && rows.any?, issues: issues, identity: %i[group member])
        end
      end
    end
  end
end
