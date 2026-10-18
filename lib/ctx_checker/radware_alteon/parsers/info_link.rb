# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 运维修改端口别名时，物理端口号仍保持稳定。
      class InfoLink < CtxChecker::Parsers::Base
        HEADER = /\AAlias\s+Port\s+Speed\s+Duplex\s+Flow Ctrl\s+Link\z/i
        ROW = /\A(\S+)\s+(\d+)\s+\S+\s+\S+\s+(?:yes|no)\*?\s+(?:yes|no)\*?\s+(\S+)\z/i

        private

        # 链路行缺失不能证明端口已禁用或健康。
        def parse_output(text, complete:)
          rows, issues, header = [], diagnostics, false
          clean(text).each_line("\n") do |raw|
            line = raw.strip
            next if line.empty? || /\A[-\s]+\z/.match?(line)
            next if /\A-+\s+-+\s+-+\s+-+\s+--TX---RX--\s+-+\z/.match?(line)
            next if line == "* = value set by configuration; not autonegotiated."

            if HEADER.match?(line)
              issues << { code: :duplicate_interface_header } if header
              header = true
            elsif header && (match = ROW.match(line)) && match[2].to_i.positive?
              name = "#{match[1].casecmp?("mgmt") ? "mgmt" : "port"}#{Integer(match[2], 10)}"
              state = match[3].downcase
              issues << { code: :unknown_interface_state, interface: name } unless %w[up down disabled].include?(state)
              rows << { name: name, kind: :physical, admin_status: state == "disabled" ? :down : :unknown,
                oper_status: { "up" => :up, "down" => :down, "disabled" => :down }.fetch(state, :unknown),
                protocol_status: :unknown, protocol_applicable: nil }
            else
              issues << { code: :unrecognized_interface_line }
            end
          end
          issues << { code: :interface_records_missing } if header && rows.empty?
          build_result(rows, complete: complete, recognized: header, issues: issues, identity: [ :name ])
        end
      end
    end
  end
end
