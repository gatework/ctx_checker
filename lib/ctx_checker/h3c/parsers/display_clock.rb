# frozen_string_literal: true

require "date"
require "time"
require_relative "../../parsers/base"

module CtxChecker
  module H3c
    module Parsers
      # 转换 UTC 需要明确的数字时区偏移，不猜测时区名称。
      class DisplayClock < CtxChecker::Parsers::Base
        private

        # 解析 display clock，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          timestamps, zones, summer = [], [], false
          source.each_line do |raw|
            line = raw.strip
            if (match = /\A(\d{1,2}:\d{2}:\d{2}(?:\.\d+)?)\s+(\S+)\s+[A-Za-z]{3}\s+(\d{2})\/(\d{2})\/(\d{4})\z/.match(line))
              timestamps << match.captures
            elsif (match = /\ATime Zone\s*:\s*(\S+)\s+(add|minus)\s+(\d{2}):(\d{2}):(\d{2})\z/i.match(line))
              zones << match.captures
            elsif /\ASummer Time\s*:/i.match?(line)
              summer = true
            elsif !line.empty?
              @issues << { code: :unrecognized_clock_line }
            end
          end
          if timestamps.size == 1
            instant = normalize_time(timestamps.first, zones, summer)
            rows = [ { component: "system", time: instant, source: nil, synchronized: nil } ]
          else
            rows = []
            @issues << { code: :ambiguous_clock_time, count: timestamps.size }
          end
          build_result(rows, complete: complete, recognized: timestamps.any?, identity: [ :component ])
        end

        # 归一化时间戳，同时保留显式声明的时区语义。
        def normalize_time(parts, zones, summer)
          clock, zone, month, day, year = parts
          if summer || zones.size > 1
            @issues << { code: summer ? :ambiguous_daylight_saving_time : :duplicate_clock_timezone }
            return
          end
          offset = zone.casecmp?("UTC") && zones.empty? ? 0 : zone_offset(zone, zones.first)
          if offset.nil?
            @issues << { code: :unknown_clock_timezone }
            return
          end
          hours, minutes, fraction = clock.split(":")
          hours, minutes, seconds = hours.to_i, minutes.to_i, Rational(fraction)
          unless Date.valid_date?(year.to_i, month.to_i, day.to_i) && (0...24).cover?(hours) && (0...60).cover?(minutes) && (0...60).cover?(seconds)
            @issues << { code: :invalid_clock_time }
            return
          end
          (Time.utc(year.to_i, month.to_i, day.to_i, hours, minutes, seconds) - offset).iso8601(3)
        end

        # 解析支持的时区偏移，不猜测有歧义的时区标签。
        def zone_offset(zone, settings)
          return unless settings && settings.first == zone
          _name, sign, hours, minutes, seconds = settings
          return unless (0...24).cover?(hours.to_i) && (0...60).cover?(minutes.to_i) && (0...60).cover?(seconds.to_i)

          (hours.to_i * 3600 + minutes.to_i * 60 + seconds.to_i) * (sign.casecmp?("minus") ? -1 : 1)
        end
      end
    end
  end
end
