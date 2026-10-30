# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"

module CtxChecker
  module H3c
    module Parsers
      # 系统对等体才是同步服务器；reference ID 可能是本地时钟或 IPv6 哈希。
      class DisplayNtpServiceStatus < CtxChecker::Parsers::Base
        include SystemValues
        FIELDS = { "clock status" => :synchronized, "clock stratum" => :stratum,
          "reference clock id" => :reference, "system peer" => :peer_address,
          "clock offset" => :offset_ms, "leap indicator" => :leap }.freeze
        AUXILIARY = /\A(?:Local mode|NTP version|Clock jitter|Stability|Clock precision|Root delay|Root dispersion|Peer dispersion|Nominal frequency|Actual frequency|Reference time|System poll interval):/i

        private

        # 解析 display ntp service status，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          row, seen, local_sync = { component: "system" }, {}, []
          source.each_line("\n") do |raw|
            line = raw.strip
            next if line.empty?
            key, value = line.split(/:\s*/, 2)
            field = FIELDS[key.downcase]
            if field && value
              if seen[field]
                row[field] = nil
                @issues << { code: :duplicate_ntp_field, field: field }
              else
                row[field] = parse_field(field, value)
              end
              seen[field] = true
            elsif key.casecmp?("Sync state from NTP server to local clock")
              local_sync << value&.downcase
            elsif !line.empty? && !AUXILIARY.match?(line)
              @issues << { code: :unrecognized_ntp_line }
            end
          end
          @issues << { code: :missing_ntp_status } unless seen[:synchronized]
          apply_local_sync(row, local_sync) unless local_sync.empty?
          if local_clock?(row[:peer_address]) || row[:peer_address].nil? && local_clock?(row[:reference])
            row[:synchronized] = false
            @issues << { code: :local_ntp_reference }
          end
          build_result(seen.any? ? [ row ] : [], complete: complete, recognized: seen.any?, identity: [ :component ])
        end

        # 仅存在服务器关联不能证明设备时钟已受同步校准。
        def apply_local_sync(row, states)
          if states.any? { |state| [ "clock not synced", "clock unsynced" ].include?(state) }
            row[:synchronized] = false
            @issues << { code: :ntp_local_clock_unsynchronized }
          elsif states != [ "clock synced" ]
            row[:synchronized] = nil unless row[:synchronized] == false
            @issues << { code: :unknown_ntp_local_clock_state }
          end
        end

        # 识别本地参考时钟，避免视为已同步的外部对等体。
        def local_clock?(value)
          /\A(?:LOCAL\(\d+\)|LOCL|127\.127\.1\.\d+)\z/i.match?(value.to_s)
        end

        # 解释单个支持的命令字段，不丢弃其他无关事实。
        def parse_field(field, value)
          parsed = case field
          when :synchronized then { "synchronized" => true, "unsynchronized" => false }[value.downcase]
          when :stratum then value.to_i if /\A\d+\z/.match?(value) && (0..16).cover?(value.to_i)
          when :leap then value.to_i(2) if /\A[01]{2}\z/.match?(value)
          when :offset_ms
            match = /\A(-?\d+(?:\.\d+)?)\s*ms\z/i.match(value)
            measurement(match[1], field: field, component: "system") if match
          when :reference, :peer_address then value unless /\A(?:none|--)\z/i.match?(value)
          end
          @issues << { code: :invalid_ntp_field, field: field } if parsed.nil? && !%i[reference peer_address].include?(field)
          parsed
        end
      end
    end
  end
end
