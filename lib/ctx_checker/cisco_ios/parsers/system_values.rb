# frozen_string_literal: true

require "date"

module CtxChecker
  module CiscoIos
    module Parsers
      # 仅在 Cisco 命令语义一致时共享小型值转换方法。
      module SystemValues
        NUMBER = /[+-]?\d+(?:\.\d+)?/

        private

        # 映射组件回显状态，不将缺失解释为健康。
        def component_status(value)
          case value.to_s.strip.downcase
          when "ok", "normal", "good", "green", "on", "powered-up" then :ok
          when "warning", "minor", "yellow" then :warning
          when "critical", "major", "red", "shutdown" then :critical
          when "fail", "failed", "faulty", "bad", "off", "no input power", "non-operational" then :failed
          when "absent", "not present", "not installed", "notsupported/none" then :absent
          else :unknown
          end
        end

        # 解析支持的数值字段，并拒绝格式错误的测量值。
        def numeric(token)
          return unless /\A#{NUMBER}\z/.match?(token.to_s)

          value = Float(token)
          value if value.finite?
        end

        # 外部数值无效时降低证据完整性，不使类型化记录构建失败。
        def checked_number(token, issues:, component:, nonnegative: false)
          return if %w[N/A --].include?(token.to_s.upcase)

          value = numeric(token)
          return value if value && (!nonnegative || value >= 0)

          issues << { code: :invalid_numeric_value, component: component }
          nil
        end

        # 将利用率归一化为经过校验的百分比。
        def percentage(token)
          value = numeric(token)
          value if value && value.between?(0, 100)
        end

        # 保留无法解释的回显行诊断。
        def unparsed(number) = { code: :unparsed_row, line: number }

        # 读数冲突不能抹除已明确观察到的组件故障。
        def most_severe_status(states)
          ranks = { ok: 0, absent: 1, unknown: 2, warning: 3, failed: 4, critical: 5 }
          states.max_by { |state| ranks.fetch(state) }
        end
      end
    end
  end
end
