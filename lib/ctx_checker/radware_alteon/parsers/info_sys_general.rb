# frozen_string_literal: true

require "date"
require "time"
require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 通用信息提供设备本地时间及其明确的 GMT 偏移。
      class InfoSysGeneral < CtxChecker::Parsers::Base
        private

        # 仅投影当前时钟，不使用启动、应用或保存时间戳。
        def parse_output(text, complete:)
          lines = clean(text).lines.map(&:strip)
          clocks = lines.grep(/\ASystem Information at\b/)
          zones = lines.grep(/\ATime zone:/)
          @issues << { code: :ambiguous_clock_time, count: clocks.size } unless clocks.one?
          @issues << { code: :ambiguous_clock_timezone, count: zones.size } unless zones.one?
          instant = normalize_time(clocks.first, zones.first) if clocks.one? && zones.one?
          rows = clocks.any? ? [ { component: "system", time: instant, source: "system_clock", synchronized: nil } ] : []
          build_result(rows, complete: complete, recognized: clocks.any?, identity: [ :component ])
        end

        # 计算偏差前，要求日期、星期、时钟与数字偏移均有效。
        def normalize_time(clock_line, zone_line)
          clock = /\ASystem Information at (\d{2}:\d{2}:\d{2}) (Sun|Mon|Tue|Wed|Thu|Fri|Sat) ([A-Z][a-z]{2}) (\d{1,2}), (\d{4})\z/.match(clock_line)
          offset = /\ATime zone:\s*.+\(GMT offset ([+-])(\d{2}):(\d{2})\)\z/.match(zone_line)
          unless offset && offset[2].to_i < 24 && offset[3].to_i < 60
            @issues << { code: :clock_offset_unknown }
            return
          end
          unless clock && clock[1].split(":").map(&:to_i).zip([ 24, 60, 60 ]).all? { |value, limit| value < limit }
            raise ArgumentError, "Invalid clock"
          end
          date = Date.strptime("#{clock[3]} #{clock[4]} #{clock[5]}", "%b %d %Y")
          raise ArgumentError, "Invalid clock weekday" unless Date::ABBR_DAYNAMES[date.wday] == clock[2]

          Time.iso8601("#{date.iso8601}T#{clock[1]}#{offset[1]}#{offset[2]}:#{offset[3]}").iso8601
        rescue ArgumentError
          @issues << { code: :invalid_clock_time }
          nil
        end
      end
    end
  end
end
