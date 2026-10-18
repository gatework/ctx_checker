# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 区分管理处理器与业务处理器的利用率采样。
      class StatsMpCpu < CtxChecker::Parsers::Base
        WINDOWS = [ 1, 4, 64 ].freeze

        private

        # 要求各文档规定的 MP 时间窗完整，无效读数保持未知。
        def parse_output(text, complete:)
          rows, headers = [], 0
          clean(text).each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            if line == "CPU utilization:"
              headers += 1
            elsif (match = /\AcpuUtil(\d+)Seconds? \(time base\):\s*(\S+)\z/.match(line))
              seconds = match[1].to_i
              value = /\A\d+(?:\.\d+)?%\z/.match?(match[2]) ? Float(match[2].delete_suffix("%"), exception: false) : nil
              valid = WINDOWS.include?(seconds) && value&.finite? && value.between?(0, 100)
              @issues << { code: :invalid_cpu_measurement, line: number } unless valid
              rows << { component: "MP", scope: "management_plane", window_seconds: seconds, utilization: valid ? value : nil }
            elsif !line.empty? && !/\A-+\z/.match?(line)
              @issues << { code: :unrecognized_cpu_line, line: number }
            end
          end
          @issues << { code: :cpu_header_invalid } unless headers == 1
          missing = WINDOWS - rows.map { |row| row[:window_seconds] }
          @issues << { code: :missing_cpu_windows, count: missing.size } if missing.any?
          build_result(rows, complete: complete, recognized: rows.any?, identity: %i[component scope window_seconds])
        end
      end
    end
  end
end
