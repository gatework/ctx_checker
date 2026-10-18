# frozen_string_literal: true

require_relative "../../parsers/base"
require "ctx_parser/results"

module CtxChecker
  module Hillstone
    module Parsers
      # 分离传感器视图，避免单个硬件章节格式错误抹除其他结果。
      class ShowEnvironment < CtxChecker::Parsers::Base
        SECTIONS = { "Temperature information(C)" => :temperature, "Fan information" => :environment, "Power information" => :power }.freeze
        HEADERS = { temperature: /\ADescription\s+Temperature\s+Range\z/, environment: /\ADescription\s+Status\z/,
          power: /\ADescription\s+Status\z/ }.freeze
        STATES = { "fine" => :ok, "normal" => :ok, "ok" => :ok, "failed" => :failed, "fault" => :failed,
          "faulty" => :failed, "error" => :failed, "warning" => :warning, "absent" => :absent }.freeze
        NUMBER = /-?\d+(?:\.\d+)?/

        private

        # 跟踪各已声明章节，并分别要求其具备表头与测量值。
        def parse_output(text, complete:)
          rows = { temperature: [], environment: [], power: [] }
          issues = rows.transform_values { diagnostics }
          contexts, section, header = [], nil, false
          clean(text).each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            if (match = /\A(.+ information(?:\(C\))?):\z/.match(line))
              section, header = SECTIONS[match[1]], false
              contexts << { section: section, rows: 0, headers: 0 } if section
              issues.each_value { |items| items << { code: :unrecognized_environment_section, line: number } } unless section
            elsif section && HEADERS.fetch(section).match?(line)
              header = true
              contexts.last[:headers] += 1
            elsif line.empty? || /\A[-=]+\z/.match?(line)
              next
            elsif section && header
              record = section == :temperature ? temperature(line, issues[section]) : hardware(line, section, issues[section])
              if record
                rows[section] << record
                contexts.last[:rows] += 1
              else
                issues[section] << { code: :unrecognized_environment_row, line: number }
              end
            elsif section
              issues[section] << { code: :environment_header_missing, line: number }
            else
              issues.each_value { |items| items << { code: :unrecognized_environment_row, line: number } }
            end
          end
          contexts.each do |context|
            if context[:rows].zero? || context[:headers] != 1
              issues[context[:section]] << { code: :incomplete_environment_section }
            end
          end
          CtxParser::Results.new(by_dimension: rows.to_h do |dimension, records|
            identity = dimension == :temperature ? [ :component ] : %i[component kind]
            [ dimension, build_result(records, complete: complete, recognized: records.any?, issues: issues[dimension], identity: identity) ]
          end)
        end

        # 保留设备给出的范围，不推测边界相等时是否触发告警。
        def temperature(line, issues)
          match = /\A(\S+)\s+(\S+)\s+(#{NUMBER})\s*-\s*(#{NUMBER})\z/.match(line)
          return unless match
          component, raw, low, high = match.captures
          value = /\A#{NUMBER}\z/.match?(raw) ? Float(raw, exception: false) : nil
          low, high = Float(low), Float(high)
          valid = value&.finite? && low.finite? && high.finite? && low <= high
          issues << { code: :invalid_temperature_measurement, component: component } unless valid
          { component: component, value: valid ? value : nil, low_alarm: low.finite? ? low : nil,
            high_alarm: high.finite? ? high : nil, high_comparison: nil, status: :unknown }
        end

        # 仅明确状态词才能证明风扇和电源正常。
        def hardware(line, dimension, issues)
          match = /\A(\S+)\s+(\S+(?:\s+\S+)*)\z/.match(line)
          return unless match
          component, text = match.captures
          state = STATES.fetch(text.downcase, :unknown)
          issues << { code: :unrecognized_component_state, component: component } if state == :unknown
          if dimension == :power
            { component: component, kind: :power_supply, status: state, present: state == :absent ? false : (state == :unknown ? nil : true) }
          else
            { component: component, kind: :fan, status: state }
          end
        end
      end
    end
  end
end
