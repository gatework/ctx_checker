# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"

module CtxChecker
  module H3c
    module Parsers
      # 应用内存使用量必须来自同一物理内存池中经过确认的缓存调整行。
      class DisplayMemory < CtxChecker::Parsers::Base
        include SystemValues
        LEGACY_FIELDS = { "System Total Memory(bytes)" => :total, "Total Used Memory(bytes)" => :used, "Used Rate" => :rate }.freeze

        private

        # 解析 display memory，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          return legacy_memory(source, complete: complete) if /^\s*System Total Memory\(bytes\):/.match?(source)

          rows, contexts, sections = [], [], []
          context, scope, unit, columns, current, section = nil, "physical", nil, nil, nil, nil
          source.each_line do |raw|
            line = raw.strip
            if /\A(?:Container memory statistics|Memory statistics|The statistics about memory).*measured in (KB|bytes)(?:\(Available\))?:\z/i.match?(line)
              unit = line.match(/measured in (KB|bytes)/i)[1].casecmp?("KB") ? 1024 : 1
              scope = line.start_with?("Container") ? "container" : "physical"
              context, columns, current = nil, nil, nil
              sections << (section = { scope: scope, samples: 0 })
            elsif (match = /\A((?:Chassis \d+ )?Slot \d+(?: CPU \d+)?):\z/i.match(line))
              contexts << (context = { component: scope_name(match[1]), scope: scope, samples: 0 })
              columns, current = nil, nil
            elsif /\ATotal\s+Used\s+Free\b/.match?(line)
              columns = line.split
            elsif (match = /\AMem:\s+(\S+)\s+(\S+)\s+(\S+)(?:\s+.*)?\z/.match(line))
              if context && unit
                values = line.delete_prefix("Mem:").split
                if columns.nil? || values.size != columns.size
                  @issues << { code: :incomplete_memory_row, component: context[:component] }
                end
                record = memory_record(context[:component], scope, unit, match.captures)
                rows << record
                current = { record: record, raw: record.dup, values: (columns || []).zip(values).to_h, adjustments: 0 }
                context[:samples] += 1
                section[:samples] += 1 if section
              else
                @issues << { code: :missing_memory_scope_or_unit }
              end
            elsif (match = /\A-\/\+ Buffers\/Cache:\s+(\S+)\s+(\S+)\z/i.match(line))
              adjust_cache(current, match.captures, unit)
            elsif !line.empty? && !/\A(?:Swap:|LowMem:|HighMem:)/i.match?(line)
              @issues << { code: :unrecognized_memory_line }
            end
          end
          contexts.each do |entry|
            @issues << { code: :missing_memory_sample, component: entry[:component], scope: entry[:scope] } if entry[:samples].zero?
          end
          sections.each do |entry|
            @issues << { code: :missing_memory_section, scope: entry[:scope] } if entry[:samples].zero?
          end
          build_result(rows, complete: complete, recognized: rows.any?, identity: %i[component scope])
        end

        # 旧交换机仅报告物理内存使用量，不能证明缓存调整后的应用使用量。
        def legacy_memory(source, complete:)
          values, seen = {}, {}
          source.each_line do |raw|
            line = raw.strip
            next if line.empty?

            key, value = line.split(/:\s*/, 2)
            field = LEGACY_FIELDS[key]
            unless field && value
              @issues << { code: :unrecognized_memory_line }
              next
            end
            if seen[field]
              values[field] = nil
              @issues << { code: :duplicate_memory_field, field: field, component: "system" }
            else
              values[field] = if field == :rate
                match = /\A(#{NUMBER})%\z/i.match(value)
                measurement(match && match[1], field: :utilization, component: "system", percent: true)
              else
                count(value, field: :memory, component: "system")
              end
            end
            seen[field] = true
          end
          total, used, rate = values.values_at(:total, :used, :rate)
          valid = total && total.positive? && used && used <= total && rate && (rate - used.fdiv(total) * 100).abs < 1
          @issues << { code: :inconsistent_memory_totals, component: "system" } unless valid
          row = { component: "system", scope: "physical", utilization: valid ? used.fdiv(total) * 100 : nil,
            total_bytes: total, used_bytes: used, free_bytes: nil, basis: :used_including_cache }
          build_result([ row ], complete: complete, recognized: true, identity: %i[component scope])
        end

        # 由兼容的容量与使用量测量计算内存利用率。
        def memory_record(component, scope, unit, values)
          total, used, free = values.map { |value| count(value, field: :memory, component: component) }
          valid = total && total.positive? && used && free && used <= total && free <= total && (scope == "container" || used + free == total)
          @issues << { code: :inconsistent_memory_totals, component: component } unless valid
          { component: component, scope: scope, utilization: valid ? used.fdiv(total) * 100 : nil,
            total_bytes: total && total * unit, used_bytes: used && used * unit, free_bytes: scope == "physical" && free ? free * unit : nil,
            basis: scope == "container" ? :used_total : :used_including_cache }
        end

        # 仅在平台明确报告时扣除可回收内存。
        def adjust_cache(current, values, unit)
          unless current && current[:record][:scope] == "physical"
            @issues << { code: :unscoped_memory_cache_adjustment }
            return
          end
          row, raw, fields = current.values_at(:record, :raw, :values)
          current[:adjustments] += 1
          used, free = values.map { |value| count(value, field: :memory, component: row[:component]) }
          buffers, cached = fields.values_at("Buffers", "Cached").map { |value| count(value, field: :memory, component: row[:component]) }
          valid = raw[:utilization] && used && free && buffers && cached && current[:adjustments] == 1 &&
            (used + free) * unit == raw[:total_bytes] && used * unit == raw[:used_bytes] - (buffers + cached) * unit &&
            free * unit == raw[:free_bytes] + (buffers + cached) * unit
          unless valid
            row.replace(raw.merge(utilization: nil, basis: :unknown))
            @issues << { code: :invalid_memory_cache_adjustment, component: row[:component] }
            return
          end
          row.merge!(used_bytes: used * unit, available_bytes: free * unit,
            utilization: (used * unit).fdiv(raw[:total_bytes]) * 100, basis: :used_minus_cache)
        end
      end
    end
  end
end
