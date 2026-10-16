# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"

module CtxChecker
  module H3c
    module Parsers
      # 风扇托盘保留机框与槽位身份；空槽位不直接判为故障。
      class DisplayFan < CtxChecker::Parsers::Base
        include SystemValues

        private

        # 解析 display fan，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows, location, current, table, seen, contexts, context, fanless = [], "system", nil, false, {}, [], nil, {}
          source.each_line do |raw|
            line = raw.strip
            if (match = /\A((?:Chassis \d+ )?Slot \d+|Chassis \d+)\s*:\z/i.match(line))
              location, current, table = scope_name(match[1]), nil, false
              contexts << (context = { component: location, count: 0 })
            elsif context && line.casecmp?("Fan-less")
              row = { component: "#{location}/fan", kind: :fan, status: :absent }
              rows << row
              fanless[location] = row
              context[:count] += 1
              current, table = nil, false
            elsif (match = /\AFan(?: Frame)?\s+(\d+)(?:\s*:\s*|\s+)(?:State\s*:\s*(\S+))?\z/i.match(line))
              current = { component: "#{location}/fan #{match[1]}", kind: :fan, status: :unknown }
              rows << current
              context[:count] += 1 if context
              if match[2]
                current[:status] = component_state(match[2], component: current[:component])
                seen[current.object_id] = true
              end
            elsif (match = /\AState\s*:\s*(\S+)\z/i.match(line)) && current
              if seen[current.object_id]
                current[:status] = :unknown
                @issues << { code: :duplicate_component_state, component: current[:component] }
              else
                current[:status] = component_state(match[1], component: current[:component])
              end
              seen[current.object_id] = true
            elsif /\AFan No\.\s+State\s+Speed(?:\s+Description)?\z/i.match?(line)
              table = true
            elsif table && (match = /\A(\d+)\s+(\S+)\s+(?:\d+|--)(?:\s+\S+)?\z/.match(line))
              component = "#{location}/fan #{match[1]}"
              rows << { component: component, kind: :fan, status: component_state(match[2], component: component) }
              context[:count] += 1 if context
            elsif !line.empty? && !/\A(?:-+|(?:Prefer )?Airflow Direction:.*)\z/i.match?(line)
              @issues << { code: :unrecognized_fan_line }
            end
          end
          contexts.each do |entry|
            @issues << { code: :missing_fan_scope_records, component: entry[:component] } if entry[:count].zero?
          end
          # 同一作用域已有实际风扇托盘时，fanless 声明不能覆盖它。
          fanless.each do |scope, row|
            next unless rows.any? { |entry| entry[:component].start_with?("#{scope}/fan ") }

            row[:status] = :unknown
            @issues << { code: :conflicting_fan_presence, component: row[:component] }
          end
          @issues << { code: :missing_component_state } if rows.any? { |row| row[:status] == :unknown }
          build_result(rows, complete: complete, recognized: rows.any?, identity: %i[component kind])
        end
      end
    end
  end
end
