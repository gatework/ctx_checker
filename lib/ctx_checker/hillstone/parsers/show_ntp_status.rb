# frozen_string_literal: true

require "date"
require_relative "../../parsers/base"
require "ctx_parser/values"

module CtxChecker
  module Hillstone
    module Parsers
      # 上次同步尝试与已配置对等体不能证明当前系统已同步。
      class ShowNtpStatus < CtxChecker::Parsers::Base
        private

        # 逐对等体解析，同时保留系统同步证据缺失的状态。
        def parse_output(text, complete:)
          source = clean(text)
          rows, clients, versions, settings = [], [], [], []
          source.each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            next if line.empty?

            if (match = /\Antp client is (enabled|disabled), authentication is (enabled|disabled)\z/i.match(line))
              clients << match[1].downcase
            elsif (match = /\Antp version is ([1-4])\z/i.match(line))
              versions << match[1]
            elsif /\Antp query-interval is \d+(?: minute(?:s)?)?, max-adjustment time is \d+(?: seconds?)?\z/i.match?(line)
              settings << line
            elsif (match = /\Antp server (\S+?)(?:, (.+))?\z/i.match(line))
              row = parse_peer(match[1], match[2], number)
              rows << row if row
            else
              @issues << { code: :unrecognized_ntp_line, line: number }
            end
          end
          @issues << { code: :duplicate_ntp_field, field: :version } if versions.size > 1
          @issues << { code: :duplicate_ntp_field, field: :settings } if settings.size > 1
          @issues << { code: :missing_ntp_status } if clients.empty?
          @issues << { code: :duplicate_ntp_field, field: :client } if clients.size > 1
          synchronized = false if clients == [ "disabled" ]
          @issues << { code: :ntp_system_status_unavailable } unless synchronized == false
          rows.unshift(component: "system", synchronized: synchronized) unless clients.empty?
          build_result(rows, complete: complete, recognized: clients.any?, identity: [ :component ])
        end

        # 设备提供虚拟路由器时，将其纳入对等体身份。
        def parse_peer(host, options, number)
          unless valid_peer?(host)
            @issues << { code: :invalid_ntp_peer, line: number }
            return
          end
          fields = {}
          Array(options&.split(/,\s*/)).each do |option|
            key, value = peer_option(option, number)
            next unless key
            if fields.key?(key)
              @issues << { code: :duplicate_ntp_field, field: key, line: number }
              fields[key] = nil
            else
              fields[key] = value
            end
          end
          peer = CtxParser::Values.ip_address?(host) ? CtxParser::Values.ip_address(host) : host.downcase
          { component: "peer/#{fields[:vrouter] || 'unspecified'}/#{peer}", peer_address: peer, synchronized: nil,
            last_sync_status: fields[:last_sync_status] || :unknown, last_sync_at: nil }
        end

        # 未知选项作为诊断保留，不能误判为同步证据。
        def peer_option(option, number)
          if (match = /\Avrouter (\S+)\z/.match(option))
            [ :vrouter, match[1] ]
          elsif (match = /\Akey (\d+)\z/.match(option))
            [ :key, match[1] ]
          elsif option == "prefer"
            [ :prefer, true ]
          elsif (match = /\Alast sync: (\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) \(([^)]+)\)\z/.match(option))
            [ :last_sync_status, sync_attempt(match, number) ]
          else
            @issues << { code: :unrecognized_ntp_field, line: number }
            nil
          end
        end

        # 本地时间戳在确定偏移前保留为不可用于偏差评估的证据。
        def sync_attempt(match, number)
          Date.iso8601(match[1])
          unless match[2].split(":").map(&:to_i).zip([ 24, 60, 60 ]).all? { |value, limit| value < limit }
            raise ArgumentError, "Invalid local clock"
          end
          @issues << { code: :ntp_last_sync_offset_unknown, line: number }
          return :failed if match[3] == "Error"
          return :succeeded if match[3] == "Success"

          @issues << { code: :unknown_ntp_last_sync_status, line: number }
          :unknown
        rescue ArgumentError
          @issues << { code: :invalid_ntp_last_sync_time, line: number }
          :unknown
        end

        # 服务器名称仅接受主机名或主机地址，不接受任意 CLI 片段。
        def valid_peer?(text)
          return true if CtxParser::Values.ip_address?(text)
          return false if text.match?(/\A[\d.]+\z/) || text.length > 253

          text.delete_suffix(".").split(".", -1).all? { |label| /\A[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\z/.match?(label) }
        end
      end
    end
  end
end
