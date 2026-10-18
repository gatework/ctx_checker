# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module Hillstone
    module Parsers
      # 命名 CPU 端口与队列分别保留计数器，不叠加可能重叠的值。
      class ShowCpuCntr < CtxChecker::Parsers::Base
        ERROR_FIELDS = %w[InBadOctets InBadPkts InMACRcvErrors InCRCAlignErrors].freeze
        INFORMATIONAL_FIELDS = %w[InGoodOctets InGoodPkts InUnicastPkts InBroadcastPkts InMulticastPkts InControlPkts
          InOver1518Pkts OutGoodOctets OutGoodPkts OutUnicastPkts OutBroadcastPkts OutMulticastPkts OutControlPkts
          Pkts64Octets Pkts65to127Octets Pkts128to255Octets Pkts256to511Octets Pkts512to1023Octets Pkts1024toMaxOctets].freeze
        UNKNOWN_FIELDS = %w[InUndersizePkts InOversizePkts InFragments InJabbers DropEvents Collisions OutDropDeferrals
          SingleCollisions MultipleCollisions ExcessiveCollisions LateCollisions].freeze
        FIELDS = (ERROR_FIELDS + INFORMATIONAL_FIELDS + UNKNOWN_FIELDS).freeze
        CELL = /\G\s*([A-Za-z][A-Za-z0-9]*):\s*(\S+)(?=\s|\z)/

        private

        # 顶部流量汇总包含歧义拼接列，不据此生成健康事实。
        def parse_output(text, complete:)
          records, contexts = [], []
          context, queue, summary = nil, nil, false
          clean(text).each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            if /\Acpu Port Send\s+Rev Counter:\z/i.match?(line)
              summary = true
            elsif (match = /\A([A-Za-z][A-Za-z0-9_\/.-]*), physical port (\d+):\z/i.match(line))
              context = { component: "cpu/#{match[1]}/physical_port_#{match[2]}", fields: [], queues: [] }
              contexts << context
              queue, summary = nil, false
            elsif context && (match = /\A(\d+) (RX|TX) Queue\(s\):\z/i.match(line))
              queue = { direction: match[2].downcase, count: match[1].to_i, ids: [], headers: 0 }
              context[:queues] << queue
            elsif line.empty? || /\A[-=]+\z/.match?(line)
              next
            elsif summary && /\A(?:Port\s+Receive\s+Send|port-\d+(?:\s+\d+){1,2})\z/i.match?(line)
              next
            elsif context && queue
              parse_queue(line, number, context, queue, records)
            elsif context
              parse_fields(line, number, context, records)
            else
              @issues << { code: :unrecognized_cpu_counter_row, line: number }
            end
          end
          contexts.each { |entry| validate_context(entry) }
          build_result(records, complete: complete, recognized: contexts.any?, identity: %i[component metric])
        end

        # 独立解析每个带标签字段，保留指标语义未知的状态。
        def parse_fields(line, number, context, records)
          position = 0
          until /\A\s*\z/.match?(line[position..])
            match = CELL.match(line, position)
            unless match
              @issues << { code: :unrecognized_cpu_counter_row, line: number }
              break
            end
            field, raw = match.captures
            context[:fields] << field
            unless FIELDS.include?(field)
              @issues << { code: :unrecognized_cpu_counter_field, line: number }
            end
            value = /\A\d+\z/.match?(raw) ? Integer(raw, 10) : nil
            @issues << { code: :invalid_cpu_counter_value, line: number } unless value
            category = ERROR_FIELDS.include?(field) ? :error : INFORMATIONAL_FIELDS.include?(field) ? :informational : :unknown
            metric = field.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
            records << counter(context[:component], metric, category, value)
            position = match.end(0)
          end
        end

        # 队列错误作为独立观测，不叠加到硬件端口总数。
        def parse_queue(line, number, context, queue, records)
          direction = queue[:direction] == "rx" ? "In" : "Out"
          if /\AQueue ID\s+#{direction} Pkts\s+#{direction} Bytes\s+Errors\z/i.match?(line)
            queue[:headers] += 1
          elsif queue[:headers].positive? && (match = /\A(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\z/.match(line))
            id, packets, bytes, errors = match.captures.map { |value| Integer(value, 10) }
            queue[:ids] << id
            component = "#{context[:component]}/#{queue[:direction]}_queue_#{id}"
            records << counter(component, "packets", :informational, packets)
            records << counter(component, "bytes", :informational, bytes)
            records << counter(component, "errors", :error, errors)
          else
            @issues << { code: :unrecognized_cpu_queue_row, line: number }
          end
        end

        # 使用显式字段与队列数量识别截断或重复的组件块。
        def validate_context(context)
          missing = FIELDS - context[:fields]
          @issues << { code: :cpu_counter_fields_missing, component: context[:component], count: missing.size } if missing.any?
          directions = context[:queues].map { |queue| queue[:direction] }
          unless directions.sort == %w[rx tx]
            @issues << { code: :cpu_counter_queue_sections_incomplete, component: context[:component] }
          end
          context[:queues].each do |queue|
            unless queue[:headers] == 1 && queue[:ids].size == queue[:count] && queue[:ids].uniq.size == queue[:count]
              @issues << { code: :cpu_counter_queue_count_mismatch, component: context[:component], scope: queue[:direction] }
            end
          end
        end

        # 本命令计数器未提供运行时长或重置时间点。
        def counter(component, metric, category, value)
          { component: component, metric: metric, category: category, value: value, discontinuity: nil }
        end
      end
    end
  end
end
