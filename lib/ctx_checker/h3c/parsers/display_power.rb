# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"

module CtxChecker
  module H3c
    module Parsers
      # 逐电源评估；电源缺失时仍需区分槽位是否应有模块。
      class DisplayPower < CtxChecker::Parsers::Base
        include SystemValues

        private

        # 解析 display power，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows, location, columns, contexts, context = [], "system", nil, [], nil
          source.each_line("\n") do |raw|
            line = raw.strip
            if (match = /\A((?:Chassis \d+ )?Slot \d+|Chassis \d+)\s*:\z/i.match(line))
              location, columns = scope_name(match[1]), nil
              contexts << (context = { component: location, count: 0 })
            elsif (match = /\APowerID\s+State\s+Mode\s+Current\(A\)\s+Voltage\(V\)\s+Power\(W\)(?:\s+(FanDirection))?(?:\s+(Switch))?\z/i.match(line))
              columns = match.captures.compact.map(&:downcase)
            elsif columns && (match = /\A(\d+)\s+(\S+)\s+(?:AC|DC|--)\s+#{NUMBER}\s+#{NUMBER}\s+(#{NUMBER})(?:\s+(\S+))?(?:\s+(\S+))?\z/i.match(line)) && match.captures.drop(3).compact.size == columns.size
              row = power_record(location, match[1], match[2], match[3])
              metadata = columns.zip(match.captures.drop(3).compact).to_h
              if metadata.key?("switch") && !metadata["switch"].casecmp?("on")
                row[:status] = :unknown if row[:status] == :ok
                @issues << { code: :power_switch_not_on, component: row[:component] }
              end
              rows << row
              context[:count] += 1 if context
            elsif (match = /\APower\s+(\d+)\s+State:\s*(\S+)\z/i.match(line))
              rows << power_record(location, match[1], match[2], nil)
              context[:count] += 1 if context
            elsif !line.empty? && !/\A(?:-+|Input Power:\s*(?:#{NUMBER}\s*(?:W|\(W\))|--|N\/?A|error))\z/i.match?(line)
              @issues << { code: :unrecognized_power_line }
            end
          end
          contexts.each do |entry|
            @issues << { code: :missing_power_scope_records, component: entry[:component] } if entry[:count].zero?
          end
          build_result(rows, complete: complete, recognized: rows.any?, identity: %i[component kind])
        end

        # 构建包含状态与测量值的归一化电源记录。
        def power_record(location, id, state, value)
          component = "#{location}/power #{id}"
          status = component_state(state, component: component)
          watts = measurement(value, field: :watts, component: component)
          if watts&.negative?
            watts = nil
            @issues << { code: :invalid_measurement, component: component, field: :watts }
          end
          { component: component, kind: :power_supply, status: status,
            present: status == :absent ? false : (status == :unknown ? nil : true), watts: watts }
        end
      end
    end
  end
end
