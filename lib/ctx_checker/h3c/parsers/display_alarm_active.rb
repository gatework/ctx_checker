# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module H3c
    module Parsers
      # 保留当前告警身份与严重级别，不复制设备自由文本消息。
      class DisplayAlarmActive < CtxChecker::Parsers::Base
        SEVERITIES = { "critical" => :critical, "major" => :critical, "minor" => :warning,
          "error" => :critical, "warning" => :warning, "notice" => :info, "info" => :info }.freeze

        private

        # 解析 display alarm active，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows, header, empty = [], false, false
          source.each_line do |raw|
            line = raw.strip
            if /\ASeq\s+Level\s+Time\s+Info\z/i.match?(line)
              header = true
            elsif (match = /\A(\d+)\s+(\S+)\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+.+\z/.match(line))
              severity = SEVERITIES.fetch(match[2].downcase, :unknown)
              @issues << { code: :unrecognized_alarm_severity } if severity == :unknown
              rows << { component: "system", alarm_id: match[1], severity: severity, active: true, count: 1 }
            elsif /\ANo active alarms\.?\z/i.match?(line)
              empty = true
            elsif !line.empty? && !/\A-+\z/.match?(line)
              @issues << { code: :unrecognized_alarm_line }
            end
          end
          if empty && rows.empty?
            rows << { component: "system", alarm_id: "summary", severity: :info, active: false, count: 0 }
          elsif empty
            @issues << { code: :contradictory_alarm_summary }
          end
          build_result(rows, complete: complete, recognized: (header && rows.any?) || empty, identity: %i[component alarm_id])
        end
      end
    end
  end
end
