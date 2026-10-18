# frozen_string_literal: true

require_relative "../port_counter_parser"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 以太网子计数器与接口错误总数分别保留。
      class StatsPortEther < CtxChecker::RadwareAlteon::PortCounterParser
        HEADER = /\AEthernet statistics for port (\d+):\z/i
        METRICS = { "dot3StatsFCSErrors" => :crc_errors, "dot3StatsCarrierSenseErrors" => :out_carrier_errors }.freeze
        CONTEXT = %w[dot3StatsAlignmentErrors dot3StatsSingleCollisionFrames dot3StatsMultipleCollisionFrames
          dot3StatsSQETestErrors dot3StatsDeferredTransmissions dot3StatsLateCollisions dot3StatsExcessiveCollisions
          dot3StatsInternalMacTransmitErrors dot3StatsFrameTooLongs dot3StatsInternalMacReceiveErrors].freeze

        private

        # 将各 IEEE 计数器绑定到其明确的数据端口标题。
        def parse_output(text, complete:)
          blocks, issues, current = [], diagnostics, nil
          clean(text).each_line("\n") do |raw|
            line = raw.strip
            next if line.empty? || /\A-+\z/.match?(line)

            if (match = HEADER.match(line)) && match[1].to_i.positive?
              current = { interface: "port#{Integer(match[1], 10)}", values: {}, seen: Hash.new(0) }
              blocks << current
            elsif current && (match = /\A(dot3\w+):\s+(\S+)\z/.match(line)) && (METRICS.key?(match[1]) || CONTEXT.include?(match[1]))
              record_value(current, match, issues)
            elsif current && /\Adot3CollFrequencies \[1-15\]:\s+NA\z/.match?(line)
              next
            else
              issues << { code: :unrecognized_counter_line }
              current = nil if /statistics/i.match?(line)
            end
          end
          rows = blocks.flat_map { |block| counter_records(block, issues) }
          build_port_result(rows, complete: complete, recognized: blocks.any?, issues: issues)
        end

        # 保留精确整数采样，重复测量使对应指标失效。
        def record_value(block, match, issues)
          value = match[2]
          issues << { code: :invalid_counter_value, interface: block[:interface] } unless /\A(?:\d+|NA)\z/.match?(value)
          return unless (metric = METRICS[match[1]])

          block[:seen][metric] += 1
          if block[:seen][metric] > 1
            block[:values][metric] = nil
            issues << { code: :duplicate_counter_value, interface: block[:interface], metric: metric }
          else
            block[:values][metric] = /\A\d+\z/.match?(value) ? Integer(value, 10) : nil
          end
        end

        # 不能根据无关的零计数推断缺失的 FCS 或载波错误。
        def counter_records(block, issues)
          METRICS.values.map do |metric|
            issues << { code: :counter_value_missing, interface: block[:interface], metric: metric } unless block[:seen][metric].positive?
            { interface: block[:interface], metric: metric, value: block[:values][metric], discontinuity: nil,
              unit: metric == :out_carrier_errors ? :events : :packets, scope: :mac }
          end
        end
      end
    end
  end
end
