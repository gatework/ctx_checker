# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module CiscoIos
    module Parsers
      # Facility 告警表示当前状态，与历史 syslog 记录区分处理。
      class ShowFacilityAlarmStatus < CtxChecker::Parsers::Base
        private

        # 解析 show facility alarm status，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          records, issues, totals, severities = [], [], [], []
          clean(text).each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty? || /\A[- ]+\z/.match?(line) || /\ASource\s+(?:Time\s+)?Severity\s+/.match?(line)

            if (match = /\ASystem Totals\s+Critical:\s*(\d+)\s+Major:\s*(\d+)\s+Minor:\s*(\d+)\z/i.match(line))
              totals << match.captures.map { |value| Integer(value, 10) }
            elsif (match = /\A(.+?)\s+(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d+\s+\d{4}\s+\d{2}:\d{2}:\d{2}\s+)?(CRITICAL|MAJOR|MINOR|INFO)\s+.+?\s+\[(\d+)\]\z/i.match(line))
              severity = match[2].upcase
              severities << severity
              records << { component: match[1].strip, alarm_id: match[3],
                severity: { "CRITICAL" => :critical, "MAJOR" => :critical, "MINOR" => :warning, "INFO" => :info }.fetch(severity), active: true, count: 1 }
            else
              issues << { code: :unparsed_row, line: number }
            end
          end
          if !totals.one? || totals.first != %w[CRITICAL MAJOR MINOR].map { |severity| severities.count(severity) }
            issues << { code: :alarm_count_mismatch }
          end
          if records.empty? && totals == [ [ 0, 0, 0 ] ] && issues.empty?
            records << { component: "system", alarm_id: "facility_summary", severity: :info, active: false, count: 0 }
          end
          build_result(records, complete: complete, recognized: totals.any? || records.any?, issues: issues, identity: %i[component alarm_id])
        end
      end
    end
  end
end
