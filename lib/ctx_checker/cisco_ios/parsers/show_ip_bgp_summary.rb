# frozen_string_literal: true

require_relative "../../parsers/base"
require "ctx_parser/values"

module CtxChecker
  module CiscoIos
    module Parsers
      # 仅以 BGP 汇总表声明的最后一列作为权威会话状态。
      class ShowIpBgpSummary < CtxChecker::Parsers::Base
        ADDRESS_FAMILY = "ipv4_unicast".freeze
        HEADER = /\ANeighbor\s+V\s+AS\s+MsgRcvd\s+MsgSent\s+TblVer\s+InQ\s+OutQ\s+Up\/Down\s+State\/PfxRcd\z/i
        STATES = { "idle" => :idle, "active" => :active, "connect" => :connect, "opensent" => :opensent,
          "openconfirm" => :openconfirm, "established" => :established, "shutdown" => :shutdown,
          "idle (admin)" => :shutdown }.freeze

        private

        # 使用作用域与行身份，避免不同地址族或 VRF 相互覆盖。
        def parse_output(text, complete:)
          text = clean(text).gsub(/State\/\s*\n\s*PfxRcd/, "State/PfxRcd")
          rows, issues = [], diagnostics
          scope = { vrf: "default", afi_safi: self.class::ADDRESS_FAMILY }
          sections = []
          section = { header: false, empty: false, count: 0, scope_fields: [], scope: scope }
          sections << section
          pending = nil
          text.each_line("\n").with_index(1) do |source, number|
            line = source.strip
            next if line.empty? || line.match?(/\A[-= ]+\z/)

            if HEADER.match?(line)
              section[:header] = true
            elsif (change = parse_scope(line, scope, issues, number))
              issues << { code: :truncated_peer } if pending
              pending = nil
              next_scope, declared_fields = change
              if section[:header] || section[:empty] || section[:count].positive? || (section[:scope_fields] & declared_fields).any?
                section = { header: false, empty: false, count: 0, scope_fields: [] }
                sections << section
              end
              section[:scope_fields] |= declared_fields
              scope = next_scope
              section[:scope] = scope
            elsif line.match?(/\A(?:No (?:BGP )?neighbors(?: found)?\.?|0 (?:BGP )?neighbors)\z/i)
              section[:empty] = true
            elsif parse_statistics(line, section, scope, issues, number)
              next
            elsif CtxParser::Values.ip_address?(line)
              issues << { code: :unparsed_row, line: number - 1 } if pending
              pending = line
            elsif peer_row?(line) || (pending && line.match?(/\A4\s/))
              line = "#{pending} #{line}" if pending
              pending = nil
              row = parse_peer(line, scope)
              if row
                rows << row
                section[:count] += 1
                issues << { code: :missing_neighbor_header, line: number } unless section[:header]
              else
                issues << { code: :unparsed_peer, line: number }
              end
            elsif auxiliary?(line)
              next
            else
              issues << { code: :unparsed_row, line: number }
            end
          end
          issues << { code: :truncated_peer } if pending
          sections.each { |entry| validate_section(entry, issues) }
          recognized = sections.any? { |entry| section_empty?(entry) || entry[:header] && entry[:count].positive? }
          scopes = sections.filter_map do |entry|
            entry[:scope] if section_empty?(entry) || entry[:header] && entry[:count].positive?
          end
          build_result(rows, complete: complete, recognized: recognized, issues: issues,
            identity: %i[vrf afi_safi peer_address], covered_scopes: scopes)
        end

        # 识别协议对等体记录，排除摘要和表头。
        def peer_row?(line) = CtxParser::Values.ip_address?(line.split(" ").first.to_s)

        # 解析单个路由作用域，不合并无关的 VRF 证据。
        def parse_scope(line, scope, issues, number)
          if (match = /\ABGP summary information for VRF (\S+), address family (.+)\z/i.match(line))
            scope = scope.merge(vrf: match[1])
            family = match[2]
            declared_fields = %i[vrf afi_safi]
          elsif (match = /\A(?:For address family:|Address family:)\s*(.+)\z/i.match(line))
            family = match[1]
            declared_fields = [ :afi_safi ]
          elsif (match = /\A(?:BGP VRF|VRF:)\s+(\S+?)(?:,.*)?\z/i.match(line))
            return [ scope.merge(vrf: match[1]), [ :vrf ] ]
          elsif line.match?(/\A(?:BGP summary information\b|BGP VRF\b|VRF:|For address family:|Address family:)/i)
            issues << { code: :invalid_protocol_scope, line: number }
            return [ { vrf: nil, afi_safi: nil }, %i[vrf afi_safi] ]
          else
            return
          end
          normalized = address_family(family)
          issues << { code: :unknown_address_family, line: number } unless normalized
          [ scope.merge(afi_safi: normalized), declared_fields ]
        end

        # 允许平台扩展读取统计信息，但不放宽对等体行校验。
        def parse_statistics(_line, _section, _scope, _issues, _number) = false

        # 未采集到邻居记录时，仅明确空表声明足以证明为空。
        def section_empty?(section) = section[:empty]

        # 每张表都必须独立核对记录行与空表声明。
        def validate_section(section, issues)
          issues << { code: :contradictory_empty } if section_empty?(section) && section[:count].positive?
          if (section[:header] || section[:scope_fields].any?) && section[:count].zero? && !section_empty?(section)
            issues << { code: :neighbor_count_unavailable }
          end
        end

        # 仅归一化支持的地址族；未知作用域保留为 nil。
        def address_family(value)
          { "ipv4 unicast" => "ipv4_unicast", "ipv6 unicast" => "ipv6_unicast",
            "l2vpn evpn" => "l2vpn_evpn" }[value.downcase.split(" ").join(" ")]
        end

        # 归一化单个路由对等体及其协议状态。
        def parse_peer(line, scope)
          match = /\A(\S+)\s+4\s+(\d+(?:\.\d+)?)\s+\d+\s+\d+\s+\d+\s+\d+\s+\d+\s+\S+\s+(.+)\z/.match(line)
          return unless match && CtxParser::Values.ip_address?(match[1])

          remote_as = as_number(match[2])
          return unless remote_as

          state, prefixes = peer_state(match[3])
          return unless state

          scope.merge(peer_address: CtxParser::Values.ip_address(match[1]), state: state, received_prefixes: prefixes, remote_as: remote_as)
        end

        # 仅在不存在平台附加标记时，末列数字才能证明会话已建立。
        def peer_state(text)
          raw_state = text.downcase
          prefixes = Integer(raw_state, 10) if raw_state.match?(/\A\d+\z/)
          [ prefixes ? :established : STATES[raw_state], prefixes ]
        end

        # 解析支持展示格式的 BGP 自治系统号。
        def as_number(text)
          parts = text.split(".").map { |value| Integer(value, 10) }
          return if parts.size == 2 && parts.any? { |value| value > 65_535 }

          value = parts.size == 2 ? parts[0] * 65_536 + parts[1] : parts.first
          value if (1..4_294_967_295).cover?(value)
        end

        # 识别说明性回显，不将其作为数据记录。
        def auxiliary?(line)
          return true if /\A\d+\/\d+ BGP path\/bestpath attribute entries using \d+ bytes of memory\z/i.match?(line)
          return true if /\A\d+ (?:BGP extended community entries using \d+ bytes of memory|received paths for inbound soft reconfiguration|networks peaked at .+)\z/i.match?(line)

          line.match?(/\A(?:BGP router identifier |BGP table version |[\d ]+(?:network entries|path entries|BGP path attribute entries|BGP AS-PATH entries|BGP community entries|BGP route-map cache entries|BGP filter-list cache entries|paths using)|BGP using |BGP activity |BGP attribute entries |BGP community entries |BGP AS path entries |Neighbor sessions:|Memory used by BGP |BGP scan interval |Scan interval )/i)
        end
      end
    end
  end
end
