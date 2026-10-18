# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module H3c
    module Parsers
      # 入站、出站查询使用相同包计数表；仅 Err 列表示错误计数。
      module CountersTable
        private

        # 按来源标签归一化支持的接口或设备计数器。
        def parse_counters(text, complete:, metric:)
          source = clean(text)
          rows, sections, section = [], [], nil
          source.each_line("\n") do |raw|
            line = raw.strip
            if /\AInterface\s+Total\s*\(pkts?\)\s+Broadcast\s*\(pkts?\)\s+Multicast\s*\(pkts?\)\s+Err\s*\(pkts?\)\z/i.match?(line)
              sections << (section = { count: 0 })
            elsif (match = /\A([A-Za-z][A-Za-z-]*\d+(?:[\/.]\d+)*)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\z/.match(line))
              unless section
                @issues << { code: :missing_counter_header }
                next
              end
              name = CtxChecker::Parsers::InterfaceNames.normalize(match[1], platform: :h3c)
              traffic = match.captures[1, 3]
              unless traffic.all? { |value| /\A(?:\d+|Overflow|--)\z/i.match?(value) }
                @issues << { code: :invalid_traffic_counter, interface: name }
              end
              rows << { interface: name, metric: metric, value: error_count(match[5], name, metric), discontinuity: nil }
              section[:count] += 1
            elsif !line.empty? && !/\A(?:-+|Overflow:\s*More than \d+ (?:decimal )?digits.*|--:\s*Not supported\.?)\z/i.match?(line)
              @issues << { code: :unrecognized_counter_line }
            end
          end
          @issues << { code: :empty_counter_table } if sections.any? { |entry| entry[:count].zero? }
          build_result(rows, complete: complete, recognized: sections.any? && rows.any?, identity: %i[interface metric])
        end

        # 提取错误计数器，不将缺少证据替换为零。
        def error_count(value, interface, metric)
          return value.to_i if /\A\d+\z/.match?(value)

          code = case value.downcase
          when "overflow" then :counter_overflow
          when "--" then :counter_unavailable
          else :invalid_counter_value
          end
          @issues << { code: code, interface: interface, metric: metric }
          nil
        end
      end
    end
  end
end
