# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../cisco_ios/parsers/system_values"
require "ctx_parser/results"

module CtxChecker
  module CiscoNxos
    module Parsers
      # CPU 使用率为 100 减空闲率；Linux 已用内存可能包含可回收缓存。
      class ShowSystemResources < CtxChecker::Parsers::Base
        include CtxChecker::CiscoIos::Parsers::SystemValues

        private

        # 解析 show system resources，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          cpu, memory, cpu_issues, memory_issues = [], [], diagnostics, diagnostics
          caches, statuses = [], []
          kernel_cache = {}
          duplicate_cache = false
          clean(text).each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty?

            if (match = /\ACPU(?:\s*(\d+))? states\s*:\s*(#{NUMBER})% user,\s*(#{NUMBER})% kernel,\s*(#{NUMBER})% idle\z/i.match(line))
              values = match.captures.drop(1).map { |value| percentage(value) }
              valid = values.all? && (values.sum - 100).abs <= 0.2
              cpu_issues << { code: :invalid_cpu_value, line: number } unless valid
              cpu << { component: match[1] ? "cpu #{match[1]}" : "processor", scope: "system", window_seconds: 1,
                utilization: valid ? (100 - values.last).round(3) : nil, interrupt_utilization: nil }
            elsif (match = /\AMemory usage:\s*(\d+)K total,\s*(\d+)K used,\s*(\d+)K free\z/i.match(line))
              total, used, free = match.captures.map { |value| Integer(value, 10) * 1024 }
              valid = total.positive? && used + free == total
              memory_issues << { code: :inconsistent_memory_totals, line: number } unless valid
              memory << { component: "system", scope: "system", total_bytes: total, used_bytes: used, free_bytes: free,
                available_bytes: nil, utilization: valid ? used.fdiv(total) * 100 : nil, basis: :used_including_cache, status: nil }
            elsif (match = /\A(\d+)K buffers,\s*(\d+)K cache\z/i.match(line))
              caches << match.captures.sum { |value| Integer(value, 10) * 1024 }
            elsif (match = /\AKernel (buffers|cached)\s*:\s*(\d+)K Used\z/i.match(line))
              key = match[1].downcase
              if kernel_cache.key?(key)
                duplicate_cache = true
                memory_issues << { code: :duplicate_memory_cache, line: number }
              end
              kernel_cache[key] = Integer(match[2], 10) * 1024
            elsif (match = /\ACurrent memory status:\s*(.+)\z/i.match(line))
              state = match[1].casecmp?("severe") ? :critical : component_status(match[1])
              memory_issues << { code: :unknown_memory_status, line: number } if state == :unknown
              statuses << state
            elsif /\A(?:Load average:|Processes\s*:|Kernel vmalloc:\s*\d+K total,\s*\d+K free\z)/i.match?(line)
              next
            elsif /\ACPU/i.match?(line)
              cpu_issues << unparsed(number)
            elsif /\A(?:Memory|Kernel|Current memory|\d+K buffers)/i.match?(line)
              memory_issues << unparsed(number)
            else
              cpu_issues << unparsed(number)
              memory_issues << unparsed(number)
            end
          end
          memory_issues << { code: :incomplete_memory_cache } if kernel_cache.size == 1
          caches << kernel_cache.values.sum if kernel_cache.size == 2 && !duplicate_cache
          memory_issues << { code: :duplicate_memory_cache } if caches.size > 1
          memory_issues << { code: :duplicate_memory_status } if statuses.size > 1
          if memory.empty? && statuses.any?
            memory_issues << { code: :memory_fields_missing }
            memory << { component: "system", scope: "system", total_bytes: nil, used_bytes: nil, free_bytes: nil,
              available_bytes: nil, utilization: nil, basis: :unknown, status: nil }
          end
          memory.each do |record|
            record[:status] = most_severe_status(statuses) if statuses.any?
            next unless caches.one? && record[:utilization] && !duplicate_cache

            if caches.first <= record[:used_bytes]
              record[:basis] = :used_minus_cache
              record[:used_bytes] -= caches.first
              record[:available_bytes] = record[:total_bytes] - record[:used_bytes]
              record[:utilization] = record[:used_bytes].fdiv(record[:total_bytes]) * 100
            else
              memory_issues << { code: :inconsistent_memory_cache }
            end
          end
          CtxParser::Results.new(by_dimension: {
            cpu: build_result(cpu, complete: complete, recognized: cpu.any?, issues: cpu_issues, identity: %i[component scope window_seconds]),
            memory: build_result(memory, complete: complete, recognized: memory.any?, issues: memory_issues, identity: %i[component scope])
          })
        end
      end
    end
  end
end
