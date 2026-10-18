# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../cisco_ios/parsers/system_values"
require "ctx_parser/results"

module CtxChecker
  module CiscoNxos
    module Parsers
      # 每个环境章节分别产生类型化组件观测。
      class ShowEnvironment < CtxChecker::Parsers::Base
        include CtxChecker::CiscoIos::Parsers::SystemValues
        HEADERS = /\A(?:[- ]+|\(?Watts\s*\)?(?:\s+\(?Watts\s*\)?)*|\(?Celsius\)?(?:\s+\(?Celsius\)?)*|Module\s+Sensor|Clock\s+Model|Fan\s+Model|Power\s+Actual|Supply\s+Model|Actual\s+Power|Module\s+Model|Output\s+Capacity|N\/A - Per module|Voltage:)/i
        POWER_VALUE = /(?:#{NUMBER}\s*W|N\/A(?:\s*W)?|--)/i

        private

        # 解析 show environment，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          @rows = { temperature: [], environment: [], power: [] }
          @problems = @rows.transform_values { diagnostics }
          @section = nil
          @section_size = 0
          @power_columns = nil
          clean(text).each_line("\n").with_index(1) do |source, number|
            line = source.strip
            next if line.empty?
            next if section_line(line) || header_line(line)
            next if @section == :fan && /\AFan Zone Speed:\s*Zone\s+\d+:/i.match?(line)
            next if parse_temperature(line) || parse_component(line) || parse_power(line)
            next if @section == :summary && /\A(?:Power Supply redundancy|Total Power |Total Grid|Cumulative Power)/i.match?(line)

            dimension = { temperature: :temperature, fan: :environment, clock: :environment, power: :power, module: :environment, summary: :power }[@section]
            (dimension ? [ @problems[dimension] ] : @problems.values).each { |issues| issues << unparsed(number) }
          end
          finish_section
          CtxParser::Results.new(by_dimension: @rows.to_h do |dimension, rows|
            identity = dimension == :temperature ? [ :component ] : %i[component kind]
            [ dimension, build_result(rows, complete: complete, recognized: rows.any?, issues: @problems[dimension], identity: identity) ]
          end)
        end

        # 识别环境章节内的行类型。
        def section_line(line)
          section = case line
          when /\ATemperature:\z/i then :temperature
          when /\AFan:\z/i then :fan
          when /\AClock:\z/i then :clock
          when /\APower Supply:\z/i then :power
          when /\APower Usage Summary:\z/i then :summary
          when /\AModule\s+Model.*Status/i then :module
          else return false
          end
          finish_section
          @section = section
          @section_size = section_rows.size
          @power_columns = nil if section == :power
          true
        end

        # 行被截断时，不能将已声明的输入列误当作额定容量。
        def header_line(line)
          if @section == :power && /\ASupply\s+Model\s+Output\b/i.match?(line)
            @power_columns = /\bInput\b/i.match?(line) ? 3 : 2
          end
          HEADERS.match?(line)
        end

        # 选择属于当前环境章节的数据行。
        def section_rows
          dimension = { temperature: :temperature, fan: :environment, clock: :environment, power: :power, module: :environment }[@section]
          dimension ? @rows[dimension] : []
        end

        # 独立完成当前环境章节，不影响其他章节的结果。
        def finish_section
          return unless @section && @section != :summary && section_rows.size == @section_size

          dimension = %i[fan clock module].include?(@section) ? :environment : @section
          @problems[dimension] << { code: :empty_environment_section, scope: @section.to_s }
        end

        # 归一化温度传感器及其回显阈值。
        def parse_temperature(line)
          return false unless @section == :temperature

          match = /\A(\S+)\s+(.+?)\s+(#{NUMBER}|N\/A)\s+(#{NUMBER}|N\/A)\s+(#{NUMBER}|N\/A)\s+(.+)\z/i.match(line)
          return false unless match

          component = "#{match[1]}/#{match[2]}"
          high_alarm, high_warning, value = match.captures[2, 3].map do |token|
            checked_number(token, issues: @problems[:temperature], component: component)
          end
          # NX-OS 使用 -127 表示传感器阈值不可用或不适用。
          high_alarm = nil if high_alarm == -127
          high_warning = nil if high_warning == -127
          @rows[:temperature] << { component: component, value: value, low_alarm: nil, low_warning: nil,
            high_warning: high_warning, high_alarm: high_alarm, high_comparison: :gt, status: component_status(match[6]) }
          true
        end

        # 归一化单个环境组件及其运行状态。
        def parse_component(line)
          return false unless %i[fan clock].include?(@section)

          if (match = /\AFan Air Filter\s*:\s*(.+)\z/i.match(line))
            @rows[:environment] << { component: "fan air filter", kind: :unknown,
              status: match[1].casecmp?("NotSupported") ? :absent : component_status(match[1]) }
          elsif @section == :fan && (match = /\A(\S+)\s+\S+\s+\S+(?:\s+(?:front-to-back|back-to-front))?\s+(.+)\z/i.match(line))
            @rows[:environment] << { component: "fan #{match[1]}", kind: :fan, status: component_status(match[2]) }
          elsif (match = /\A(\S+)\s+.+?\s+(Ok|Normal|Good|Fail|Failed|Faulty|Absent|Not Present|NotSupported\/None)\z/i.match(line))
            @rows[:environment] << { component: "#{@section} #{match[1]}", kind: @section, status: component_status(match[2]) }
          else
            return false
          end
          true
        end

        # 归一化电源测量值及回显状态。
        def parse_power(line)
          return false unless %i[power module].include?(@section)

          match = /\A(\S+)\s+\S+\s+(#{POWER_VALUE})\s+(#{POWER_VALUE})(?:\s+(#{POWER_VALUE}))?\s+(.+)\z/i.match(line)
          return false unless match
          return false if @section == :module && match[4]
          return false if @section == :power && @power_columns && @power_columns != (match[4] ? 3 : 2)

          state = component_status(match[5])
          if @section == :module
            @rows[:environment] << { component: "module #{match[1]}", kind: :module, status: state }
          else
            component = "power supply #{match[1]}"
            # 部分平台在输出与容量之间插入 Actual Input 列。
            watts, capacity = [ match[2], match[4] || match[3] ].map do |token|
              checked_number(token.sub(/W\z/i, "").strip, issues: @problems[:power], component: component, nonnegative: true)
            end
            if match[4]
              checked_number(match[3].sub(/W\z/i, "").strip, issues: @problems[:power], component: component, nonnegative: true)
            end
            @rows[:power] << { component: component, kind: :power_supply, status: state,
              present: state == :absent ? false : nil, watts: watts, capacity_watts: capacity }
          end
          true
        end

        # NX-OS 拼写差异仅在本平台处理；未报告的风扇状态保持未知。
        def component_status(value)
          case value.to_s.strip.downcase
          when "shut" then :critical
          when "failure", "fail/shutdown", "powered-dn" then :failed
          else super
          end
        end
      end
    end
  end
end
