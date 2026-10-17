# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"
require "ctx_parser/results"

module CtxChecker
  module CiscoIos
    module Parsers
      # Catalyst 组件块与 ASR 传感器表分别保留覆盖状态。
      class ShowEnvironmentAll < CtxChecker::Parsers::Base
        include SystemValues

        private

        # 解析 show environment all，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          @rows = { temperature: [], environment: [], power: [] }
          @problems = @rows.transform_values { diagnostics }
          @switch = "active"
          @temperature = nil
          @sensor_table = false
          @component_table = nil
          clean(text).each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty? || /\A[- ]+\z/.match?(line)
            next if catalyst_line(line) || stack_component_line(line) || sensor_line(line)
            next if /\A(?:Sensor List:|Sensor\s+Location|SW\s+PID\s+Serial#)/.match?(line)

            @problems.each_value { |issues| issues << unparsed(number) }
          end
          results = @rows.to_h do |dimension, rows|
            identity = dimension == :temperature ? [ :component ] : %i[component kind]
            [ dimension, build_result(rows, complete: complete, recognized: rows.any?, issues: @problems[dimension], identity: identity) ]
          end
          CtxParser::Results.new(by_dimension: results)
        end

        # Catalyst StackWise Virtual 在传感器后按交换机报告电源和风扇托盘。
        def stack_component_line(line)
          case line
          when /\ASwitch:(\d+)\z/i
            @switch = Regexp.last_match(1)
            @sensor_table, @component_table = false, nil
          when /\APower\s+Fan States\z/i
            @component_table = :power
          when /\AFan\s+Fan States\z/i
            @component_table = :fan
          when /\ASupply\s+Model No\s+Type\s+Capacity\s+Status\s+(?:\d+\s*)+\z/i,
            /\ATray\s+Status\s+(?:\d+\s*)+\z/i
            return false unless @component_table
          else
            if @component_table == :power && (match = /\A(PS\d+)\s+\S+\s+(?:AC|DC)\s+(\d+(?:\.\d+)?)\s+W\s+(\S+)\s+(.+)\z/i.match(line))
              status = stack_component_status(match[3], match[4])
              return false unless status
              @rows[:power] << { component: "switch #{@switch}/power supply #{match[1]}", kind: :power_supply,
                status: status, present: status != :absent, watts: nil, capacity_watts: Float(match[2]) }
            elsif @component_table == :fan && (match = /\A(FM\d+)\s+(\S+)\s+(.+)\z/i.match(line))
              status = stack_component_status(match[2], match[3])
              return false unless status
              @rows[:environment] << { component: "switch #{@switch}/fan tray #{match[1]}", kind: :fan, status: status }
            else
              return false
            end
          end
          true
        end

        # 单个风扇故障优先于电源或托盘的整体正常状态。
        def stack_component_status(parent, fans)
          values = fans.split
          return unless values.all? { |value| /\A(?:good|bad|ok|fail|failed|N\/A)\z/i.match?(value) }

          states = [ component_status(parent), *values.reject { |value| value.casecmp?("N/A") }.map { |value| component_status(value) } ]
          most_severe_status(states)
        end

        # 保留当前交换机身份；本命令不承诺覆盖整个堆叠。
        def catalyst_line(line)
          case line
          when /\A(?:Switch (\d+) )?FAN (\S+) is (.+)\z/i
            @switch = Regexp.last_match(1) if Regexp.last_match(1)
            @rows[:environment] << { component: "switch #{@switch}/fan #{Regexp.last_match(2)}", kind: :fan,
              status: component_status(Regexp.last_match(3)) }
          when /\ASwitch (\d+): SYSTEM TEMPERATURE is (.+)\z/i
            @switch = Regexp.last_match(1)
            @rows[:environment] << { component: "switch #{@switch}/temperature", kind: :overall, status: component_status(Regexp.last_match(2)) }
          when /\A(.+?) Temperature Value:\s*(#{NUMBER}) Degree Celsius\z/i
            component = "switch #{@switch}/#{Regexp.last_match(1).downcase}"
            value = checked_number(Regexp.last_match(2), issues: @problems[:temperature], component: component)
            @temperature = { component: component, value: value,
              low_alarm: nil, low_warning: nil, high_warning: nil, high_alarm: nil, status: :unknown }
            @rows[:temperature] << @temperature
          when /\A(?:System )?Temperature State:\s*(\S+)\z/i
            return false unless @temperature

            state = component_status(Regexp.last_match(1))
            if @temperature[:status] == :unknown
              @temperature[:status] = state
            else
              @problems[:temperature] << { code: :duplicate_sensor_state, component: @temperature[:component] }
              @temperature[:status] = most_severe_status([ @temperature[:status], state ])
            end
          when /\A(Yellow|Red) Threshold\s*:\s*(#{NUMBER}) Degree Celsius\z/i
            return false unless @temperature

            field = Regexp.last_match(1).casecmp?("yellow") ? :high_warning : :high_alarm
            @problems[:temperature] << { code: :duplicate_sensor_threshold, component: @temperature[:component] } if @temperature[field]
            @temperature[field] = checked_number(Regexp.last_match(2), issues: @problems[:temperature], component: @temperature[:component])
          when /\A(\d+[AB])\s+\S+\s+\S+\s+(.+?)\s+(Good|Bad|N\/A)\s+(Good|Bad|N\/A)\s+(\d+)\z/i
            match = Regexp.last_match
            state = component_status(match[2])
            state = most_severe_status([ state, :failed ]) if [ match[3], match[4] ].any? { |value| value.casecmp?("bad") }
            @rows[:power] << { component: "power supply #{match[1]}", kind: :power_supply, status: state,
              present: state == :absent ? false : nil, watts: nil, capacity_watts: Integer(match[5], 10) }
          when /\ASensor List:.*Environmental Monitoring/i
            @sensor_table = true
          else
            return false
          end
          true
        end

        # 根据读数单位区分传感器类型；仅有转速或风扇百分比不能判定健康。
        def sensor_line(line)
          return false unless @sensor_table

          cells = line.split(/\s{2,}/)
          return false unless cells.size == 4

          sensor, location, state, reading = cells
          component = "#{location}/#{sensor}"
          status = component_status(state)
          if (match = /\A(#{NUMBER}) Celsius\z/i.match(reading))
            value = checked_number(match[1], issues: @problems[:temperature], component: component)
            @rows[:temperature] << { component: component, value: value, low_alarm: nil, low_warning: nil,
              high_warning: nil, high_alarm: nil, status: status }
            if state.start_with?("Fan Speed")
              @rows[:environment] << { component: component, kind: :fan, status: :unknown }
            end
          elsif /\A(?:PEM|Power)/i.match?(sensor)
            @rows[:power] << { component: component, kind: :power_rail, status: status, present: nil, watts: nil, capacity_watts: nil }
          elsif /\A#{NUMBER}\s+(?:mV|V|V AC|mA|A)\z/i.match?(reading)
            @rows[:environment] << { component: component, kind: :voltage, status: status }
          else
            return false
          end
          true
        end
      end
    end
  end
end
