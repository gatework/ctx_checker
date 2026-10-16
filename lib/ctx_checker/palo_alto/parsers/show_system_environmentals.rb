# frozen_string_literal: true

require_relative "../../parsers/base"
require "ctx_parser/result_set"

module CtxChecker
  module PaloAlto
    module Parsers
      # 特定章节的硬件传感器不能证明未出现的电源或风扇已被覆盖。
      class ShowSystemEnvironmentals < CtxChecker::Parsers::Base
        SECTIONS = { "thermal" => :temperature, "fans" => :environment, "fan tray" => :environment,
          "power" => :power, "power supplies" => :power }.freeze

        private

        # 解析 show system environmentals，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows = { temperature: [], environment: [], power: [] }
          issues = rows.transform_values { [] }
          section, header, sections, section_rows = nil, nil, [], 0
          source.each_line.with_index(1) do |raw, number|
            line = raw.strip
            next if line.empty?
            if (match = /\A-+\s*([^-]+?)\s*-+\z/.match(line))
              empty_section(section, section_rows, issues)
              section, header = match[1].downcase, nil
              section_rows = 0
              sections << section
              issues.each_value { |items| items << { code: :unrecognized_environment_section, line: number } } unless SECTIONS.key?(section)
            elsif line.match?(/\ASlot\s+Description\s+Alarm\s+/)
              header = line
            elsif SECTIONS.key?(section) && header
              dimension = SECTIONS.fetch(section)
              if (match = /\A(\S+)\s+(.+?)\s+(True|False)\s+(.+)\z/i.match(line))
                section_rows += 1
                component = "#{match[1]}/#{match[2].strip}"
                alarm = match[3].casecmp?("true")
                status = alarm ? :critical : :ok
                values = match[4].split
                case section
                when "thermal"
                  measurements = values.map { |value| numeric(value) }
                  expected = header.include?("Min C") && header.include?("Max C") ? 3 : 1
                  valid = measurements.size == expected && measurements.none?(&:nil?)
                  issues[:temperature] << { code: :invalid_temperature_measurement, component: component } unless valid
                  rows[:temperature] << { component: component, value: valid ? measurements.first : nil,
                    low_alarm: valid && expected == 3 ? measurements[1] : nil,
                    high_alarm: valid && expected == 3 ? measurements[2] : nil, status: status }
                when "power supplies", "fan tray"
                  present = values.one? && %w[true false].include?(values.first.downcase) ? values.first.casecmp?("true") : nil
                  status = :absent if !alarm && present == false
                  issues[dimension] << { code: :invalid_presence, component: component } if present.nil?
                  rows[dimension] << if section == "power supplies"
                    { component: component, kind: :power_supply, status: status, present: present }
                  else
                    { component: component, kind: :fan, status: status }
                  end
                when "fans", "power"
                  valid = sensor_values?(section, header, values)
                  issues[dimension] << { code: :invalid_environment_measurement, component: component } unless valid
                  status = :unknown if !valid && !alarm
                  if valid && limits_invalid?(section, header, values)
                    issues[dimension] << { code: :invalid_environment_thresholds, component: component }
                    status = :unknown unless alarm
                  elsif valid && outside_limits?(section, header, values)
                    issues[dimension] << { code: :conflicting_environment_state, component: component } unless alarm
                    status = :failed unless alarm
                  end
                  if section == "fans" && header.match?(/Operational\s*\z/) && values == [ "False" ]
                    issues[dimension] << { code: :conflicting_environment_state, component: component } unless alarm
                    status = :failed
                  end
                  if section == "power"
                    rows[:power] << { component: component, kind: :power_rail, status: status }
                  else
                    rows[:environment] << { component: component, kind: :fan, status: status }
                  end
                end
              else
                issues[dimension] << { code: :unrecognized_environment_row, line: number }
              end
            else
              issues.each_value { |items| items << { code: :unrecognized_environment_row, line: number } }
            end
          end
          empty_section(section, section_rows, issues)
          if rows[:power].any? && !sections.include?("power supplies")
            issues[:power] << { code: :power_supply_status_missing }
          end
          CtxParser::ResultSet.new(results: rows.to_h do |dimension, values|
            identity = dimension == :temperature ? [ :component ] : %i[component kind]
            [ dimension, build_result(values, complete: complete, recognized: values.any?, issues: issues.fetch(dimension), identity: identity) ]
          end)
        end

        # 解析支持的数值字段，并拒绝格式错误的测量值。
        def numeric(value)
          return unless /\A-?\d+(?:\.\d+)?\z/.match?(value)
          number = Float(value)
          number if number.finite?
        end

        # 表达明确的空章节，不虚构组件记录。
        def empty_section(section, count, issues)
          return unless SECTIONS.key?(section) && count.zero?
          issues.fetch(SECTIONS.fetch(section)) << { code: :empty_environment_section, section: section }
        end

        # 检查传感器行是否包含可用的数值测量。
        def sensor_values?(section, header, values)
          if section == "fans" && header.match?(/Operational\s*\z/)
            values.one? && %w[True False].include?(values.first)
          else
            expected = if section == "fans"
              header.include?("Min RPM") ? 2 : 1
            else
              header.include?("Min V") && header.include?("Max V") ? 3 : 1
            end
            values.size == expected && values.all? { |value| (number = numeric(value)) && (section != "fans" || number >= 0) }
          end
        end

        # 识别矛盾或格式错误的传感器阈值边界。
        def limits_invalid?(section, header, values)
          section == "power" && header.include?("Min V") && header.include?("Max V") && numeric(values[1]) > numeric(values[2])
        end

        # 过期的 False 告警标志不能抹除实际观察到的设备阈值违规。
        def outside_limits?(section, header, values)
          if section == "fans" && header.include?("Min RPM")
            numeric(values[0]) < numeric(values[1])
          elsif section == "power" && header.include?("Min V") && header.include?("Max V")
            !numeric(values[0]).between?(numeric(values[1]), numeric(values[2]))
          else
            false
          end
        end
      end
    end
  end
end
