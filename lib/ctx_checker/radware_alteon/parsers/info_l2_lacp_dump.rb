# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 端口模式表可证明 LACP 已禁用，但不能虚构活跃成员状态。
      class InfoL2LacpDump < CtxChecker::Parsers::Base
        HEADER = /\APort\s+lacp\s+adminkey\s+operkey\s+selected\s+prio\s+attached\s+trunk\s+Blocked\z/i
        ROW = /\A(\d+)\s+(\S+)\s+\d+\s+\d+\s+([yn])\s+\d+\s+(\d+|--)\s+(\d+|--)\s+([yn])\z/i

        private

        # 活跃模式需要额外运行证据，不能由重复的 trunk 记录替代。
        def parse_output(text, complete:)
          issues, ports, header = diagnostics, {}, false
          clean(text).each_line("\n") do |raw|
            line = raw.strip
            next if line.empty? || /\A-+\z/.match?(line)

            if HEADER.match?(line)
              issues << { code: :duplicate_aggregation_header } if header
              header = true
            elsif header && line == "aggr"
              next
            elsif header && (match = ROW.match(line)) && match[1].to_i.positive?
              port = "port#{Integer(match[1], 10)}"
              issues << { code: :duplicate_lacp_port, interface: port } if ports.key?(port)
              ports[port] = true
              if match[2].casecmp?("off")
                unless match.captures[2..] == %w[n -- -- n]
                  issues << { code: :inconsistent_lacp_disabled_state, interface: port }
                end
              else
                issues << { code: :lacp_operational_evidence_unavailable, interface: port }
              end
            else
              issues << { code: :unrecognized_lacp_line }
            end
          end
          issues << { code: :lacp_port_records_missing } if header && ports.empty?
          build_result([], complete: complete, recognized: header, issues: issues)
        end
      end
    end
  end
end
