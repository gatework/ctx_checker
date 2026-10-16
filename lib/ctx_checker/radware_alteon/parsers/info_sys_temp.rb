# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 读取同一命令报告的传感器值及阈值语义。
      class InfoSysTemp < CtxChecker::Parsers::Base
        NUMBER = /-?\d+(?:\.\d+)?/
        STATES = { "ok" => :ok, "high" => :warning, "warning" => :warning, "critical" => :critical }.freeze

        private

        # 阈值缺失时保留未知，拒绝矛盾的汇总或范围证据。
        def parse_output(text, complete:)
          rows, highs, criticals, summaries = [], [], [], []
          clean(text).each_line.with_index(1) do |raw, number|
            line = raw.strip
            if (match = /\ASensor (\d+) has (\S+) degree Celsius\z/.match(line))
              value = /\A#{NUMBER}\z/.match?(match[2]) ? Float(match[2], exception: false) : nil
              @issues << { code: :invalid_temperature_measurement, line: number } unless value&.finite?
              rows << { component: "sensor#{match[1]}", value: value&.finite? ? value : nil, status: :unknown }
            elsif (match = /\ACurrent device temperature is (.+)\z/.match(line))
              summaries << STATES.fetch(match[1].downcase, :unknown)
            elsif (match = /\AHigh temperature is (#{NUMBER})-(#{NUMBER}) degree Celsius\z/.match(line))
              highs << match.captures.map { |value| Float(value) }
            elsif (match = /\ACritical temperature (#{NUMBER}) and above degree Celsius\z/.match(line))
              criticals << Float(match[1])
            elsif !line.empty? && ![ "Note:", "System will shutdown if it reaches Critical temperature" ].include?(line)
              @issues << { code: :unrecognized_temperature_line, line: number }
            end
          end
          valid_bounds = highs.one? && criticals.one? && highs.first.all?(&:finite?) && criticals.first.finite? &&
            highs.first.first < criticals.first && highs.first.last == criticals.first
          if valid_bounds
            rows.each { |row| row.merge!(high_warning: highs.first.first, high_alarm: criticals.first, high_comparison: :gte) }
          elsif highs.any? || criticals.any?
            @issues << { code: :temperature_thresholds_invalid }
          end
          state = summaries.one? ? summaries.first : :unknown
          @issues << { code: :temperature_summary_unavailable } if state == :unknown
          if %i[warning critical].include?(state)
            rows << { component: "device_temperature", value: nil, status: state }
          elsif state == :ok && valid_bounds && rows.any? { |row| row[:value] && row[:value] >= highs.first.first }
            @issues << { code: :temperature_state_disagreement }
          end
          build_result(rows, complete: complete, recognized: rows.any?, identity: [ :component ])
        end
      end
    end
  end
end
