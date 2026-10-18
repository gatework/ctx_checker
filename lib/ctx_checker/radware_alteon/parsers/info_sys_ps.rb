# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 报告声明的供电组合，不虚构单个电源模块身份。
      class InfoSysPs < CtxChecker::Parsers::Base
        STATES = { "ok" => :ok, "failed" => :failed, "failure" => :failed, "warning" => :warning }.freeze

        private

        # 未识别的汇总状态保持不可用，不推定冗余供电正常。
        def parse_output(text, complete:)
          rows = []
          clean(text).each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            if (match = /\A(Single|Dual) Power Supply Status:\s*(.+)\z/i.match(line))
              state = STATES.fetch(match[2].downcase, :unknown)
              @issues << { code: :unrecognized_power_state, line: number } if state == :unknown
              rows << { component: "#{match[1].downcase}_power_supply_system", kind: :power_supply, status: state, present: nil }
            elsif !line.empty?
              @issues << { code: :unrecognized_power_line, line: number }
            end
          end
          @issues << { code: :conflicting_power_arrangements } if rows.map { |row| row[:component] }.uniq.size > 1
          rows = [] if rows.map { |row| row[:component] }.uniq.size > 1
          build_result(rows, complete: complete, recognized: rows.any?, identity: %i[component kind])
        end
      end
    end
  end
end
