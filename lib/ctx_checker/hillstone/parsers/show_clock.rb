# frozen_string_literal: true

require "date"
require "time"
require_relative "../../parsers/base"

module CtxChecker
  module Hillstone
    module Parsers
      # StoneOS 命名时区可能由用户自定义，不能用于确定 UTC 偏移。
      class ShowClock < CtxChecker::Parsers::Base
        private

        # 保留已识别的设备本地时间，不猜测时区或同步状态。
        def parse_output(text, complete:)
          source = clean(text)
          zones, clocks = [], []
          source.each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            next if line.empty?

            if (match = /\ACurrent time zone:\s*(\S+)\z/i.match(line))
              zones << match[1]
            elsif (match = /\A(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})\s+(Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)\z/.match(line))
              clocks << match.captures
            else
              @issues << { code: :unrecognized_clock_line, line: number }
            end
          end
          @issues << { code: :ambiguous_clock_time, count: clocks.size } unless clocks.one?
          @issues << { code: :ambiguous_clock_timezone, count: zones.size } unless zones.one?
          instant = normalize_time(clocks.first, zones.first) if clocks.one? && zones.one?
          rows = clocks.any? ? [ { component: "system", time: instant, source: "system_clock", synchronized: nil } ] : []
          build_result(rows, complete: complete, recognized: clocks.any?, identity: [ :component ])
        end

        # 仅明确数字偏移或 UTC 标签允许计算时钟偏差。
        def normalize_time(parts, zone)
          date, clock, weekday = parts
          parsed_date = Date.iso8601(date)
          unless Date::DAYNAMES[parsed_date.wday] == weekday && clock.split(":").map(&:to_i).zip([ 24, 60, 60 ]).all? { |value, limit| value < limit }
            @issues << { code: :invalid_clock_time }
            return
          end
          offset = zone_offset(zone)
          unless offset
            @issues << { code: :clock_offset_unknown }
            return
          end
          Time.iso8601("#{date}T#{clock}#{offset}").iso8601
        rescue ArgumentError
          @issues << { code: :invalid_clock_time }
          nil
        end

        # 用户自定义时区名称不能替代实际偏移值。
        def zone_offset(zone)
          return "+00:00" if %w[UTC GMT Z].include?(zone)

          match = /\A(?:UTC|GMT)?([+-])(\d{2}):?(\d{2})\z/.match(zone)
          return unless match && match[2].to_i < 24 && match[3].to_i < 60

          "#{match[1]}#{match[2]}:#{match[3]}"
        end
      end
    end
  end
end
