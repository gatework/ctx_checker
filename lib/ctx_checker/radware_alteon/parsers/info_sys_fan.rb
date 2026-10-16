# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 保留厂商对关键与非关键风扇的区分。
      class InfoSysFan < CtxChecker::Parsers::Base
        private

        # 校验每条风扇记录，并按厂商关键性定义确定故障严重级别。
        def parse_output(text, complete:)
          rows, tables, headers = [], 0, 0
          clean(text).each_line.with_index(1) do |raw, number|
            line = raw.strip
            if line == "Fans table:"
              tables += 1
            elsif /\AFan-Number\s+Type\s+Status\s+Speed\z/.match?(line)
              headers += 1
            elsif (match = /\A(\d+)\s+(Critical|Non-critical)\s+(\S+)\s+(\S+)\z/i.match(line))
              type, state, speed = match[2].downcase, match[3].downcase, match[4]
              value = /\A\d+(?:\.\d+)?%\z/.match?(speed) ? Float(speed.delete_suffix("%"), exception: false) : nil
              valid = value&.finite? && value.between?(0, 100)
              @issues << { code: :invalid_fan_speed, line: number } unless valid
              status = case state
              when "operational" then :ok
              when "failed" then type == "critical" ? :critical : :warning
              else :unknown
              end
              @issues << { code: :unrecognized_fan_state, line: number } if status == :unknown
              if status == :ok && (!valid || value.zero?)
                status = :unknown
                @issues << { code: :fan_measurements_inconsistent, line: number }
              end
              rows << { component: "fan#{match[1]}", kind: :fan, status: status }
            elsif !line.empty? && !/\A[-\s]+\z/.match?(line)
              @issues << { code: :unrecognized_fan_row, line: number }
            end
          end
          @issues << { code: :fan_header_invalid } unless tables == 1 && headers == 1
          build_result(rows, complete: complete, recognized: rows.any?, identity: %i[component kind])
        end
      end
    end
  end
end
