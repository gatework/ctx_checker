# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"

module CtxChecker
  module H3c
    module Parsers
      # 传感器阈值取自各板卡，不使用统一猜测的温度限制。
      class DisplayEnvironment < CtxChecker::Parsers::Base
        include SystemValues
        SENSOR_ROW = /\A(?:(\d+)\s+)?(\d+|Vent)\s+((?:hotspot|inflow|outflow)\s+\d+(?:\(sub\d+\))?)\s+(#{NUMBER})\s+(#{NUMBER})\s+(#{NUMBER})\s+(#{NUMBER})(?:\s+#{NUMBER})?\z/i
        HOTSPOT_ROW = /\A(\d+)\s+hotspot(\d+)\s+[A-Za-z][A-Za-z0-9_-]*(?:[ \t]+\d+-\d+)?\s+(#{NUMBER})\s+(#{NUMBER})\s+(#{NUMBER})\s+(#{NUMBER})\s+#{NUMBER}\z/i

        private

        # 解析 display environment，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows, chassis, header, auxiliary, contexts, context = [], nil, nil, nil, [], nil
          source.each_line do |raw|
            line = raw.strip
            if (match = /\AChassis (\d+):\z/i.match(line))
              chassis = "chassis #{match[1]} "
              contexts << (context = { component: chassis.strip, count: 0 })
              header, auxiliary = nil, nil
            elsif (match = /\A(Chassis\s+)?Slot\s+Sensor\s+Temperature\s+Lower(?:Limit)?\s+Warning(?:Limit)?\s+Alarm(?:Limit)?(?:\s+Shutdown(?:Limit)?)?\z/i.match(line))
              header, auxiliary = match[1] ? :chassis : :slot, nil
            elsif /\ASlotNo\s+Temperature\s+Lower limit\s+Upper limit\z/i.match?(line)
              header, auxiliary = :legacy, nil
            elsif /\ASlot\s+Hotspot\s+(?:Sensor|Name)\s+Temperature\s+Lower\s+Warning\s+Alarm\s+Shutdown\z/i.match?(line)
              header, auxiliary = :hotspot, nil
            elsif header == :hotspot && (match = HOTSPOT_ROW.match(line))
              component = "#{chassis}slot #{match[1]}/hotspot #{match[2]}"
              values = match.captures.drop(2).map { |value| measurement(value, field: :temperature, component: component) }
              rows << temperature_record(component, values[0], low_warning: values[1], high_warning: values[2], high_alarm: values[3])
              context[:count] += 1 if context
            elsif %i[chassis slot].include?(header) && (match = SENSOR_ROW.match(line)) && (header == :chassis) == !match[1].nil?
              prefix = match[1] ? "chassis #{match[1]} " : chassis
              component = "#{prefix}#{match[2].casecmp?("vent") ? 'vent' : "slot #{match[2]}"}/#{scope_name(match[3])}"
              values = match.captures.drop(3).map { |value| measurement(value, field: :temperature, component: component) }
              rows << temperature_record(component, values[0], low_warning: values[1], high_warning: values[2], high_alarm: values[3])
              context[:count] += 1 if context
            elsif header == :legacy && (match = /\A(\d+)\s+(#{NUMBER})\s+#{NUMBER}\s+#{NUMBER}\z/i.match(line))
              component = "#{chassis}slot #{match[1]}"
              rows << temperature_record(component, measurement(match[2], field: :temperature, component: component))
              # 旧版表列不能区分警告与告警级别。
              @issues << { code: :temperature_threshold_semantics_unknown, component: component }
              context[:count] += 1 if context
            elsif (match = /\A(Fan|Power) temperature information:\z/i.match(line))
              header, auxiliary = nil, match[1].downcase
            elsif chassis && auxiliary && (match = /\A(Fan|Power) (\d+):\s*(#{NUMBER})\z/i.match(line)) && match[1].casecmp?(auxiliary)
              component = "#{chassis.strip}/#{auxiliary} #{match[2]}"
              rows << temperature_record(component, measurement(match[3], field: :temperature, component: component))
              context[:count] += 1 if context
            elsif !line.empty? && !/\A(?:-+|System temperature information \(degree centigrade\):)\z/i.match?(line)
              @issues << { code: :unrecognized_temperature_line }
            end
          end
          contexts.each do |entry|
            @issues << { code: :missing_temperature_scope_records, component: entry[:component] } if entry[:count].zero?
          end
          build_result(rows, complete: complete, recognized: rows.any?, identity: [ :component ])
        end

        # 能读取但无设备阈值的传感器仅提供测量值，不据此判定健康。
        def temperature_record(component, value, **limits)
          @issues << { code: :missing_temperature_measurement, component: component } if value.nil?
          { component: component, value: value, high_comparison: :gte, status: :unknown, **limits }
        end
      end
    end
  end
end
