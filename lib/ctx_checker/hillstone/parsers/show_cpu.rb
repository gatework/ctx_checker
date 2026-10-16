# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module Hillstone
    module Parsers
      # 保留设备报告的时间窗，不为整体平均值虚构周期。
      class ShowCpu < CtxChecker::Parsers::Base
        WINDOWS = { "1 minute" => 60, "5 minutes" => 300, "15 minutes" => 900 }.freeze

        private

        # 要求当前采样及回显声明的各标准采样时间窗均有证据。
        def parse_output(text, complete:)
          rows = []
          clean(text).each_line.with_index(1) do |raw, number|
            line = raw.strip
            if (match = /\A(Average|Current) cpu utilization\s*:\s*(\S+)\s*\z/i.match(line))
              rows << sample(match[2], scope: match[1].casecmp?("average") ? "system_average" : "system", seconds: nil)
            elsif (match = /\ALast (1 minute|5 minutes|15 minutes)\s*:\s*(\S+)\s*\z/i.match(line))
              rows << sample(match[2], scope: "system", seconds: WINDOWS.fetch(match[1].downcase))
            elsif !line.empty?
              @issues << { code: :unrecognized_cpu_line, line: number }
            end
          end
          windows = rows.select { |row| row[:scope] == "system" }.map { |row| row[:window_seconds] }
          missing = [ nil, *WINDOWS.values ] - windows
          @issues << { code: :missing_cpu_windows, count: missing.size } if missing.any?
          build_result(rows, complete: complete, recognized: rows.any?, identity: %i[component scope window_seconds])
        end

        # 无效百分比保持不可用，避免导致观测记录校验失败。
        def sample(text, scope:, seconds:)
          match = /\A(\d+(?:\.\d+)?)%\z/.match(text)
          value = match && Float(match[1], exception: false)
          valid = value&.finite? && value.between?(0, 100)
          @issues << { code: :invalid_cpu_measurement, scope: scope, window_seconds: seconds } unless valid
          { component: "system", scope: scope, window_seconds: seconds, utilization: valid ? value : nil }
        end
      end
    end
  end
end
