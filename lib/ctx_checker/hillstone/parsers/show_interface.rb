# frozen_string_literal: true

require "ipaddr"
require_relative "../../parsers/base"

module CtxChecker
  module Hillstone
    module Parsers
      # StoneOS 分别展示物理、管理、链路与 IP 协议状态。
      class ShowInterface < CtxChecker::Parsers::Base
        NAME = /(?:x?ethernet|cellular)\d+(?:\/\d+)+(?:\.\d+)?|(?:ha|mgt|aggregate|redundant|bgroup|vswitchif|vlan|loopback|tunnel)\d+(?:\.\d+)?/i
        HEADER = /\AInterface name\s+IP address\/mask\s+Zone name\s+H\s+A\s+L\s+P\s+MAC address(?:\s+Description)?\z/i
        LEGEND = /\AH:physical state;\s*A:admin state;\s*L:link state;\s*P:protocol state;\s*U:up;\s*D:down(?:;\s*K:ha keep up)?(?:;\s*C:lacp down)?\z/i
        ROW = /\A(#{NAME})\s+(\S+)\s+\S+\s+(\S)\s+(\S)\s+(\S)\s+(\S)\s+(?:[\da-f]{4}\.){2}[\da-f]{4}(?:\s+.*)?\z/i

        private

        # 识别无地址链路时，仍保留 IP 协议 down 状态。
        def parse_output(text, complete:)
          rows, issues, header = [], [], false
          clean(text).each_line do |raw|
            line = raw.strip
            next if line.empty? || /\A[-=]+\z/.match?(line) || LEGEND.match?(line)

            if HEADER.match?(line)
              issues << { code: :duplicate_interface_header } if header
              header = true
            elsif header && (match = ROW.match(line))
              row = interface_record(match, issues)
              rows << row if row
            else
              issues << { code: :unrecognized_interface_line }
            end
          end
          issues << { code: :interface_records_missing } if header && rows.empty?
          interfaces = build_result(rows, complete: complete, recognized: header, issues: issues, identity: [ :name ])
          groups = interfaces.records.select { |row| row[:kind] == :aggregate }.map do |row|
            { group: row[:name], member: nil, member_status: :unknown, oper_status: row[:oper_status] }
          end
          missing_members = groups.map { |group| { code: :aggregation_members_unavailable, group: group[:group] } }
          CtxParser::ResultSet.new(results: {
            interfaces: interfaces,
            aggregation: build_result(groups, complete: complete, recognized: header,
              issues: interfaces.issues + missing_members, identity: %i[group member])
          })
        end

        # 仅当前一单元格具有地址形式时，才解释相邻状态列。
        def interface_record(match, issues)
          name = CtxChecker::Parsers::InterfaceNames.normalize(match[1], platform: :hillstone)
          unless /\A[\da-f:.]+\/\d+\z/i.match?(match[2]) && IPAddr.new(match[2])
            issues << { code: :invalid_interface_address, interface: name }
            return
          end
          flags = match.captures[2, 4].map(&:upcase)
          unless flags.all? { |flag| %w[U D C].include?(flag) }
            issues << { code: :unknown_interface_state, interface: name }
          end
          if flags[2] == "U" && flags.first(2).include?("D")
            issues << { code: :inconsistent_interface_state, interface: name }
          end
          { name: name, kind: CtxChecker::Parsers::InterfaceNames.kind(name),
            admin_status: state(flags[1]), oper_status: state(flags[2]), protocol_status: state(flags[3]),
            protocol_applicable: !%w[0.0.0.0/0 ::/0].include?(match[2]),
            parent: name.include?(".") ? name.split(".").first : nil }
        rescue IPAddr::InvalidAddressError, IPAddr::InvalidPrefixError
          issues << { code: :invalid_interface_address, interface: name }
          nil
        end

        # HA keep-up 不能证明接口可转发普通流量。
        def state(flag)
          case flag
          when "U" then :up
          when "D", "C" then :down
          else :unknown
          end
        end
      end
    end
  end
end
