# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module PaloAlto
    module Parsers
      # 读取当前告警布尔值，不执行 PAN 类 Python 状态文本。
      class ShowSystemStateAlarms < CtxChecker::Parsers::Base
        private

        # 解析 show system state alarms，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows, issues = [], diagnostics
          source.each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            # 配置阈值和复制的 HA 对端状态不属于本地当前告警。
            next if line.empty? || line.match?(/\A(?:cfg\.|peer\.)/)
            if line.match?(/\Achassis\.alarm:\s*\{\s*\}\z/)
              rows << { component: "chassis", alarm_id: "summary", active: false, count: 0, severity: :unknown }
            elsif (match = /\A(ha\.(?:runtime\.device|app\.local)\.alarm):\s*(True|False)\z/i.match(line))
              rows << alarm(match[1], match[2])
            elsif (match = /\A(env\.[a-z0-9_.-]+):\s*\{(.+)\}\z/i.match(line))
              states = match[2].scan(/(?:\A|,)\s*'alarm':\s*(True|False)\s*(?=,|\z)/i).flatten
              if states.one?
                rows << alarm(match[1], states.first)
              else
                issues << { code: :ambiguous_alarm_state, line: number }
              end
            elsif (match = /\A((?:chassis(?:\.s\d+)?|hw\.(?:slot\d+|s\d+\.mp))\.leds):\s*\{(.+)\}\z/i.match(line))
              states = match[2].scan(/(?:\A|,)\s*'alarm':\s*(Off|Red|Green|Yellow|Amber)\s*(?=,|\z)/i).flatten
              if states.one?
                value = states.first.downcase
                rows << { component: match[1], alarm_id: "alarm_led", active: !%w[off green].include?(value),
                  severity: :unknown, count: nil }
              else
                issues << { code: :ambiguous_alarm_state, line: number }
              end
            else
              issues << { code: :unrecognized_alarm_state, line: number }
            end
          end
          build_result(rows, complete: complete, recognized: rows.any?, issues: issues, identity: %i[component alarm_id])
        end

        # 归一化单条当前告警及其严重级别。
        def alarm(component, value)
          { component: component, alarm_id: "alarm", active: value.casecmp?("true"), severity: :unknown, count: nil }
        end
      end
    end
  end
end
