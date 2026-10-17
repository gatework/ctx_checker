# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"

module CtxChecker
  module CiscoIos
    module Parsers
      # 时区缩写不等于 UTC 偏移；有歧义的本地时间保持未知。
      class ShowClockDetail < CtxChecker::Parsers::Base
        include SystemValues

        private

        # 解析 show clock detail，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          records, issues = [], diagnostics
          time_source = nil
          clean(text).each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty?

            if (match = /\A([*.]?)(\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)\s+(\S+)\s+\w{3}\s+(\w{3})\s+(\d{1,2})\s+(\d{4})\z/.match(line))
              offset = match[3]
              offset = "+0000" if %w[UTC GMT].include?(offset)
              timestamp = nil
              offset_parts = /\A[+-](\d{2}):?(\d{2})\z/.match(offset)
              if offset_parts && offset_parts[1].to_i < 24 && offset_parts[2].to_i < 60
                begin
                  raise Date::Error unless match[2].split(":").map(&:to_f).zip([ 24, 60, 60 ]).all? { |value, limit| value < limit }

                  format = match[2].include?(".") ? "%H:%M:%S.%N %z %b %d %Y" : "%H:%M:%S %z %b %d %Y"
                  timestamp = DateTime.strptime("#{match[2]} #{offset} #{match[4]} #{match[5]} #{match[6]}", format).iso8601(3)
                rescue Date::Error
                  issues << { code: :invalid_clock_time, line: number }
                end
              else
                issues << { code: :clock_timezone_unknown, line: number }
              end
              records << { component: "system", time: timestamp, source: nil, synchronized: match[1].empty? ? nil : false }
            elsif (match = /\ATime source is (.+)\z/i.match(line))
              issues << { code: :duplicate_clock_source, line: number } if time_source
              time_source = match[1]
            elsif /\A(?:Summer time|Time zone|Timezone|No time source)/i.match?(line)
              next
            else
              issues << unparsed(number)
            end
          end
          records.each { |record| record[:source] = time_source }
          build_result(records, complete: complete, recognized: records.any?, issues: issues, identity: [ :component ])
        end
      end
    end
  end
end
