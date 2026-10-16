# frozen_string_literal: true

require_relative "../port_counter_parser"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 接口累计计数与后续每秒速率表属于独立事实。
      class StatsPortIf < CtxChecker::RadwareAlteon::PortCounterParser
        HEADER = /\AInterface statistics for port (\d+):\z/i
        COLUMNS = /\AifHCIn Counters\s+ifHCOut Counters\z/i
        ROW = /\A(Octets|UcastPkts|BroadcastPkts|MulticastPkts|Discards|Errors):\s+(\S+)\s+(\S+)\z/i
        METRICS = { "discards" => %i[in_discards out_discards], "errors" => %i[in_errors out_errors] }.freeze

        private

        # 解释方向性测量前，要求存在带标签的累计计数列。
        def parse_output(text, complete:)
          blocks, issues, current, section = [], [], nil, nil
          clean(text).each_line do |raw|
            line = raw.strip
            next if line.empty? || /\A-+\z/.match?(line)

            if (match = HEADER.match(line)) && match[1].to_i.positive?
              current = { interface: "port#{Integer(match[1], 10)}", values: {}, seen: Hash.new(0) }
              blocks << current
              section = :header
            elsif current && section == :header && COLUMNS.match?(line)
              section = :cumulative
            elsif current && section == :cumulative && line.casecmp?("Per second Interface statistics:")
              section = :rate
            elsif current && %i[cumulative rate].include?(section) && (match = ROW.match(line))
              record_values(current, match, section, issues)
            else
              issues << { code: :unrecognized_counter_line }
              current = nil if /statistics|Counters/i.match?(line)
            end
          end
          rows = blocks.flat_map { |block| counter_records(block, issues) }
          build_port_result(rows, complete: complete, recognized: blocks.any?, issues: issues)
        end

        # 缺失或重复采样保持不可用；速率不能替代累计值。
        def record_values(block, match, section, issues)
          values = match.captures.last(2)
          unless values.all? { |value| /\A(?:\d+|NA)\z/i.match?(value) }
            issues << { code: :invalid_counter_value, interface: block[:interface] }
          end
          return unless section == :cumulative && (metrics = METRICS[match[1].downcase])

          metrics.zip(values).each do |metric, value|
            block[:seen][metric] += 1
            if block[:seen][metric] > 1
              block[:values][metric] = nil
              issues << { code: :duplicate_counter_value, interface: block[:interface], metric: metric }
            else
              block[:values][metric] = /\A\d+\z/.match?(value) ? Integer(value, 10) : nil
            end
          end
        end

        # 输出所有请求方向的指标，包括明确不可用的单元格。
        def counter_records(block, issues)
          METRICS.values.flatten.map do |metric|
            unless block[:seen][metric].positive?
              issues << { code: :counter_value_missing, interface: block[:interface], metric: metric }
            end
            { interface: block[:interface], metric: metric, value: block[:values][metric], discontinuity: nil }
          end
        end
      end
    end
  end
end
