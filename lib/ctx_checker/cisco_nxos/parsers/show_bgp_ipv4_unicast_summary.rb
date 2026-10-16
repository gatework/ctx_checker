# frozen_string_literal: true

require_relative "../../cisco_ios/parsers/show_ip_bgp_summary"

module CtxChecker
  module CiscoNxos
    module Parsers
      # NX-OS 在各 VRF、地址族表内独立校验已配置对等体总数。
      class ShowBgpIpv4UnicastSummary < CiscoIos::Parsers::ShowIpBgpSummary
        PEER_COUNTS = /\ABGP table version is \d+,\s*(.+?)\s+config peers (\d+),\s*capable peers (\d+)\z/i
        STATISTICS = [
          /\ADampening configured, \d+ history paths, \d+ dampened paths\z/i,
          /\A\d+ received paths for inbound soft reconfiguration\z/i,
          /\A\d+ identical, \d+ modified, \d+ filtered received paths using \d+ bytes\z/i
        ].freeze

        private

        # 缺少地址族能力时保留已观察对等体，但不声明会话健康。
        def peer_state(text)
          return super unless text.match?(/\A\d+\s+\(No Cap\)\z/i)

          @issues << { code: :peer_capability_unavailable }
          [ :unknown, nil ]
        end

        # 配置数量覆盖全部记录；具备能力的对等体数量不等于已建立数量。
        def parse_statistics(line, section, scope, issues, number)
          if (match = PEER_COUNTS.match(line))
            counts = (section[:peer_counts] ||= [])
            issues << { code: :duplicate_peer_count, line: number } unless counts.empty?
            counts << { configured: Integer(match[2], 10), capable: Integer(match[3], 10) }
            if address_family(match[1]) != scope[:afi_safi]
              issues << { code: :conflicting_address_family, line: number }
            end
          elsif line.match?(/\ABGP table version\b.*\b(?:config|capable) peers\b/i)
            issues << { code: :invalid_peer_count, line: number }
          else
            return false
          end
          true
        end

        # 仅当能力计数同样一致时，零数量才能证明空表。
        def section_empty?(section)
          super || section[:peer_counts] == [ { configured: 0, capable: 0 } ]
        end

        # 校验每条总数声明，避免重复或矛盾总数掩盖记录缺失。
        def validate_section(section, issues)
          super
          Array(section[:peer_counts]).each do |counts|
            unless counts[:configured] == section[:count]
              issues << { code: :count_mismatch, expected: counts[:configured], observed: section[:count] }
            end
            if counts[:capable] > counts[:configured]
              issues << { code: :invalid_capable_peer_count, expected: counts[:configured], observed: counts[:capable] }
            end
          end
        end

        # 可选路由统计仅接受文档明确的完整格式。
        def auxiliary?(line)
          super || STATISTICS.any? { |pattern| pattern.match?(line) }
        end
      end
    end
  end
end
