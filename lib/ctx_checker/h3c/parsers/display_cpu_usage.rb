# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"

module CtxChecker
  module H3c
    module Parsers
      # 保留每个 CPU 及其采样周期，不对机框成员取平均。
      class DisplayCpuUsage < CtxChecker::Parsers::Base
        include SystemValues

        private

        # 解析 display cpu usage，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows, components, current, table = [], [], nil, nil
          source.each_line("\n") do |raw|
            line = raw.strip
            if (match = /\A((?:Chassis \d+ )?Slot \d+(?: CPU \d+(?: Core \d+)?)?) CPU usage:\z/i.match(line))
              current = scope_name(match[1])
              components << current
            elsif /\A(?:Chassis\s+)?Slot\s+CPU\s+Last 5 sec\s+Last 1 min\s+Last 5 min\z/i.match?(line)
              table = line.start_with?("Chassis") ? 3 : 2
            elsif table && (match = /\A(\d+(?:\s+\d+){1,2})\s+(#{NUMBER})%?\s+(#{NUMBER})%?\s+(#{NUMBER})%?\z/i.match(line))
              identifiers = match[1].split
              if identifiers.size == table
                current = identifiers.zip(table == 3 ? %w[chassis slot cpu] : %w[slot cpu]).map { |id, kind| "#{kind} #{id}" }.join(" ")
                components << current
                rows.concat([ 5, 60, 300 ].zip(match.captures.drop(1)).map { |seconds, value| sample(current, seconds, value) })
              else
                @issues << { code: :missing_cpu_scope }
              end
            elsif (match = /\A(#{NUMBER})%? in last (5 seconds|1 minute|5 minutes)\z/i.match(line))
              if current
                seconds = { "5 seconds" => 5, "1 minute" => 60, "5 minutes" => 300 }.fetch(match[2].downcase)
                rows << sample(current, seconds, match[1])
              else
                @issues << { code: :missing_cpu_scope }
              end
            elsif line.empty?
              next
            else
              @issues << { code: :unrecognized_cpu_line }
            end
          end
          windows = rows.group_by { |row| row[:component] }.transform_values { |samples| samples.map { |row| row[:window_seconds] }.uniq }
          components.uniq.each do |component|
            missing = [ 5, 60, 300 ] - windows.fetch(component, [])
            @issues << { code: :missing_cpu_windows, component: component, count: missing.size } if missing.any?
          end
          build_result(rows, complete: complete, recognized: components.any?, identity: %i[component scope window_seconds])
        end

        # 构建包含采样上下文的归一化测量记录。
        def sample(component, seconds, value)
          utilization = measurement(value, field: :utilization, component: component, percent: true)
          @issues << { code: :missing_cpu_measurement, component: component, window_seconds: seconds } if utilization.nil?
          { component: component, scope: "system", window_seconds: seconds, utilization: utilization }
        end
      end
    end
  end
end
