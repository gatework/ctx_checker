# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module Hillstone
    module Parsers
      # 使用当前总量计算使用率，不将历史曲线分桶作为当前采样。
      class ShowMemory < CtxChecker::Parsers::Base
        HISTORY_SAMPLES = { "60 seconds" => 60, "60 minutes" => 60, "24 hours" => 24, "7 days" => 168 }.freeze

        private

        # 检查历史数据结构，但仅保留当前物理内存池的测量值。
        def parse_output(text, complete:)
          percentages, totals, histories = [], [], []
          header_count, history = 0, nil
          clean(text).each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            if (match = /\AThe percentage of memory utilization:\s*(\S+)\s*%\z/i.match(line))
              percentages << percentage(match[1])
              history = nil
            elsif /\Atotal\(KB\)\s+used\(KB\)\s+free\(KB\)\z/i.match?(line)
              header_count += 1
              history = nil
            elsif (match = /\AMemory utilization in last (60 seconds|60 minutes|24 hours|7 days)\(%\):\z/i.match(line))
              history = { section: match[1].downcase, indices: [], header: 0 }
              histories << history
            elsif history && line == "memoryutil"
              history[:header] += 1
            elsif history && (match = /\A(\d+)\s*:\s*(\S+)\z/.match(line))
              history[:indices] << match[1].to_i
              @issues << { code: :invalid_memory_history_value, section: history[:section] } unless percentage(match[2])
            elsif !history && header_count.positive? && (match = /\A(\d+)\s+(\d+)\s+(\d+)\z/.match(line))
              totals << match.captures.map(&:to_i)
            elsif !line.empty?
              @issues << { code: :unrecognized_memory_line, line: number }
            end
          end
          validate_histories(histories)
          row = current_record(percentages, totals, header_count)
          build_result(row ? [ row ] : [], complete: complete, recognized: percentages.any? || header_count.positive?, identity: %i[component scope])
        end

        # 仅接受有限且在设备合理范围内的百分比。
        def percentage(text)
          return unless /\A\d+(?:\.\d+)?\z/.match?(text)
          value = Float(text, exception: false)
          value if value&.finite? && value.between?(0, 100)
        end

        # 重复、缺失或截断的时间桶不能掩盖证据丢失。
        def validate_histories(histories)
          sections = histories.map { |history| history[:section] }
          missing = HISTORY_SAMPLES.keys - sections
          @issues << { code: :missing_memory_history_sections, count: missing.size } if histories.any? && missing.any?
          histories.each do |history|
            expected = (0...HISTORY_SAMPLES.fetch(history[:section])).to_a
            unless history[:header] == 1 && history[:indices].sort == expected
              @issues << { code: :incomplete_memory_history, section: history[:section] }
            end
          end
          if sections.uniq.size != histories.size
            @issues << { code: :duplicate_memory_history }
          end
        end

        # 整数汇总百分比可因截断，与已校验的总量及使用量比值相差不足一个百分点。
        def current_record(percentages, totals, header_count)
          unless totals.one? && percentages.size == 1 && header_count == 1
            @issues << { code: :missing_or_ambiguous_memory_sample }
            return
          end
          total, used, free = totals.first
          valid = total.positive? && used + free == total && percentages.first
          utilization = total.positive? ? used.fdiv(total) * 100 : nil
          valid &&= utilization && (utilization - percentages.first).abs < 1
          @issues << { code: :inconsistent_memory_totals } unless valid
          { component: "system", scope: "physical", total_bytes: total * 1024, used_bytes: used * 1024,
            free_bytes: free * 1024, utilization: valid ? utilization : nil, basis: valid ? :used_total : :unknown }
        end
      end
    end
  end
end
