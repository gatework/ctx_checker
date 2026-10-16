# frozen_string_literal: true

require "ipaddr"
require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # IP 接口索引独立于 VLAN ID 和物理数据端口号。
      class InfoL3Ip < CtxChecker::Parsers::Base
        ROW = /\A(\d+):\s+IP4\s+(\S+)\s+(\S+)\s+([^,\s]+)\s*,\s*vlan\s+(\d+),\s*(\S+),\s*BFD\s+\S+\z/i

        private

        # 将接口行限定在明确章节内，排除带编号的网关记录。
        def parse_output(text, complete:)
          rows, issues, section = [], [], :preamble
          header, interfaces, ipv6, closed = false, false, false, false
          clean(text).each_line do |raw|
            line = raw.strip
            next if line.empty? || /\A-+\z/.match?(line)

            if line.casecmp?("IP information:")
              issues << { code: :duplicate_interface_header } if header
              header = true
            elsif /\A,?Interface information:\z/i.match?(line)
              issues << { code: :duplicate_interface_header } if interfaces
              interfaces = true
              section = :interfaces
            elsif line.casecmp?("IPv6 Link Local Address Information:")
              ipv6 = true
              section = :ipv6
            elsif /\ADefault gateway information:/i.match?(line)
              closed = section == :ipv6
              section = :other
            elsif section == :preamble && /\ARouter ID:/.match?(line) || section == :other
              next
            elsif section == :interfaces && (match = ROW.match(line)) && match[1].to_i.positive?
              row = interface_record(match, issues)
              rows << row if row
            elsif section == :ipv6
              issues << { code: :ipv6_interface_evidence_unavailable }
            else
              issues << { code: :unrecognized_interface_line }
            end
          end
          issues << { code: :interface_section_incomplete } unless header && interfaces && ipv6 && closed
          issues << { code: :interface_records_missing } if interfaces && rows.empty?
          build_result(rows, complete: complete, recognized: header && interfaces, issues: issues, identity: [ :name ])
        end

        # 明确的 IP4 状态仅证明运行状态，不能推断未报告的线路协议状态。
        def interface_record(match, issues)
          name = "ipif#{Integer(match[1], 10)}"
          unless match.captures[1, 3].all? { |value| IPAddr.new(value).ipv4? } && IPAddr.new("#{match[2]}/#{match[3]}")
            issues << { code: :invalid_interface_address, interface: name }
            return
          end
          state = match[6].downcase
          issues << { code: :unknown_interface_state, interface: name } unless %w[up down].include?(state)
          { name: name, kind: :svi, admin_status: :unknown,
            oper_status: { "up" => :up, "down" => :down }.fetch(state, :unknown),
            protocol_status: :unknown, protocol_applicable: true, parent: nil }
        rescue IPAddr::InvalidAddressError, IPAddr::InvalidPrefixError
          issues << { code: :invalid_interface_address, interface: name }
          nil
        end
      end
    end
  end
end
