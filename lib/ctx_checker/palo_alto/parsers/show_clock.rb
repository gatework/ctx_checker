# frozen_string_literal: true

require "date"
require "time"
require_relative "../../parsers/base"

module CtxChecker
  module PaloAlto
    module Parsers
      # 命名本地时区缺少明确偏移，不能用于安全判断 UTC 时钟偏差。
      class ShowClock < CtxChecker::Parsers::Base
        private

        # 解析 show clock，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows, issues = [], diagnostics
          source.each_line("\n").with_index(1) do |raw, number|
            next if raw.strip.empty?
            match = /\A(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}:\d{2}:\d{2})\s+(\S+)\s+(\d{4})\z/.match(raw.strip)
            unless match
              issues << { code: :invalid_clock_output, line: number }
              next
            end
            zone = %w[UTC GMT Z].include?(match[4]) ? "+0000" : match[4]
            timestamp = clock_time(match, zone)
            issues << { code: :clock_offset_unknown, line: number } unless timestamp
            rows << { component: "system", time: timestamp, source: "system_clock", synchronized: nil }
          end
          build_result(rows, complete: complete, recognized: rows.any?, issues: issues, identity: [ :component ])
        end

        # 解析设备时钟，不虚构未知时区。
        def clock_time(match, zone)
          return unless /\A[+-]\d{2}:?\d{2}\z/.match?(zone)
          month = Date::ABBR_MONTHNAMES.index(match[1])
          year, day = Integer(match[5], 10), Integer(match[2], 10)
          return unless month && Date.valid_date?(year, month, day)
          hours, minutes, seconds = match[3].split(":").map { |part| Integer(part, 10) }
          return unless hours < 24 && minutes < 60 && seconds < 60
          offset = zone.delete(":")
          return unless offset[1, 2].to_i < 24 && offset[3, 2].to_i < 60
          Time.strptime("#{match[1]} #{day} #{match[3]} #{offset} #{year}", "%b %d %H:%M:%S %z %Y").iso8601
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
