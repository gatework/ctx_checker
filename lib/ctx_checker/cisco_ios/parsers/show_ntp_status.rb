# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"

module CtxChecker
  module CiscoIos
    module Parsers
      # IOS 显式报告系统同步状态，并使用毫秒表示偏移。
      class ShowNtpStatus < CtxChecker::Parsers::Base
        include SystemValues
        AUXILIARY = /\A(?:nominal freq|reference time|root dispersion|loopfilter state|system poll interval|ntp uptime|system time|leap time|leap direction|root delay|time resolution)/i

        private

        # 解析 show ntp status，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          records, issues = [], diagnostics
          clean(text).each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty?

            if (match = /\AClock is (synchronized|unsynchronized), stratum (\d+)(?:, reference assoc id \d+)?(?:, reference is (\S+))?\z/i.match(line))
              stratum = Integer(match[2], 10)
              issues << { code: :invalid_ntp_stratum, line: number } unless stratum.between?(0, 16)
              records << { component: "system", synchronized: match[1].casecmp?("synchronized"),
                stratum: stratum.between?(0, 16) ? stratum : nil, reference: match[3], peer: nil, offset_ms: nil, leap: nil }
            elsif (match = /\Aclock offset is (#{NUMBER}) msec(?:,|\z)/i.match(line)) && records.one?
              issues << { code: :duplicate_ntp_offset, line: number } if records.first[:offset_ms]
              records.first[:offset_ms] = checked_number(match[1], issues: issues, component: "system")
            elsif /\A%?NTP is not enabled\.?\z/i.match?(line)
              records << { component: "system", synchronized: false, stratum: nil, reference: nil, peer: nil, offset_ms: nil, leap: nil }
            elsif AUXILIARY.match?(line)
              next
            else
              issues << unparsed(number)
            end
          end
          build_result(records, complete: complete, recognized: records.any?, issues: issues, identity: [ :component ])
        end
      end
    end
  end
end
