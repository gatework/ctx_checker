# frozen_string_literal: true

require_relative "../../parsers/base"
require "ctx_parser/results"

module CtxChecker
  module PaloAlto
    module Parsers
      # PAN top 描述管理平面，并包含可回收内存。
      class ShowSystemResources < CtxChecker::Parsers::Base
        UNITS = { "KiB" => 1024, "MiB" => 1024**2, "GiB" => 1024**3, "TiB" => 1024**4 }.freeze
        NUMBER = /\d+(?:\.\d+)?/

        private

        # 解析 show system resources，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          cpus, memories, cpu_issues, memory_issues, shared_issues = [], [], diagnostics, diagnostics, diagnostics
          swap_lines = source.lines.grep(/\A\s*(?:(?:KiB|MiB|GiB|TiB)\s+)?Swap\s*:/)
          process_table = false
          source.each_line.with_index(1) do |raw, number|
            line = raw.strip
            if (match = /\A%?Cpu(?:\(s\)|(\d+))\s*:\s*(.*)\z/i.match(line))
              cpus << cpu(match, cpu_issues)
            elsif line.match?(/\A(?:(?:KiB|MiB|GiB|TiB)\s+)?Mem\s*:/)
              memories << memory(line, swap_lines, memory_issues)
            elsif line.match?(/\APID\s+USER\s+/)
              process_table = true
            elsif line.empty? || line.match?(/\A(?:top - |Tasks:|(?:(?:KiB|MiB|GiB|TiB)\s+)?Swap\s*:)/) || process_table && line.match?(/\A\d+\s+/)
              next
            else
              shared_issues << { code: :unrecognized_resource_row, line: number }
            end
          end
          CtxParser::Results.new(by_dimension: {
            cpu: build_result(cpus, complete: complete, recognized: cpus.any?, issues: shared_issues + cpu_issues,
              identity: %i[component scope window_seconds]),
            memory: build_result(memories, complete: complete, recognized: memories.any?, issues: shared_issues + memory_issues,
              identity: %i[component scope])
          })
        end

        # 归一化 CPU 利用率，并保留其采样周期。
        def cpu(match, issues)
          parts = match[2].split(",").map { |part| /\A\s*(#{NUMBER})\s*%?\s*(us|sy|ni|id|wa|hi|si|st)\s*\z/.match(part) }
          values = parts.compact.to_h { |part| [ part[2], Float(part[1]) ] }
          valid = parts.size == 8 && parts.all? && values.size == 8 && values.values.all? { |value| value.finite? && value.between?(0, 100) } &&
            (values.values.sum - 100).abs <= 1
          issues << { code: :invalid_cpu_measurement } unless valid
          { component: match[1] ? "management/cpu#{match[1]}" : "management", scope: "management_plane", window_seconds: nil,
            utilization: valid ? (100 - values.fetch("id")).round(6) : nil, interrupt_utilization: valid ? (values.fetch("hi") + values.fetch("si")).round(6) : nil }
        end

        # 仅根据可用内存，或文档明确的旧版缓存调整方式计算利用率。
        def memory(line, swap_lines, issues)
          header = /\A(?:(KiB|MiB|GiB|TiB)\s+)?Mem\s*:\s*(.*)\z/.match(line)
          unit = header[1] ? UNITS.fetch(header[1]) : 1024
          pairs = header[2].split(",").map { |part| /\A\s*(#{NUMBER})(k?)\s+(total|used|free|buffers|buff\/cache)\s*\z/.match(part) }
          values = pairs.compact.to_h { |pair| [ pair[3], bytes(pair[1], unit) ] }
          available = swap_lines.flat_map { |swap| swap.scan(/(?:\A|[\s,.])(#{NUMBER})\s+avail Mem\s*\z/).flatten }
          cached = swap_lines.flat_map { |swap| swap.scan(/(?:\A|[\s,])(#{NUMBER})k\s+cached\s*\z/).flatten }
          row = { component: "management", scope: "management_plane", total_bytes: values["total"], free_bytes: values["free"],
            used_bytes: values["used"], available_bytes: nil, utilization: nil, basis: :unknown }
          valid_units = pairs.all? { |pair| pair && (header[1] ? pair[2].empty? : pair[2] == "k") }
          valid = valid_units && pairs.size == values.size && values.values.none?(&:nil?) && row[:total_bytes]&.positive? &&
            values.values.all? { |value| value <= row[:total_bytes] }
          if valid && available.one? && swap_lines.one?
            swap_unit = /\A\s*(KiB|MiB|GiB|TiB)\s+Swap/.match(swap_lines.first)&.[](1)
            row[:available_bytes] = bytes(available.first, swap_unit ? UNITS.fetch(swap_unit) : 1024)
            valid &&= row[:available_bytes] && row[:available_bytes] <= row[:total_bytes]
            row[:used_bytes] = row[:total_bytes] - row[:available_bytes] if valid
            row[:basis] = :available if valid
          elsif valid && header[1].nil? && cached.one? && swap_lines.one? && values["buffers"] && values["used"]
            cache_bytes = bytes(cached.first, 1024)
            adjusted = cache_bytes && values["used"] - values["buffers"] - cache_bytes
            valid &&= adjusted && adjusted >= 0
            row[:used_bytes], row[:basis] = adjusted, :used_minus_cache if valid
            row[:available_bytes] = row[:total_bytes] - adjusted if valid
          else
            valid = false
          end
          if valid
            row[:utilization] = (100.0 * row[:used_bytes] / row[:total_bytes]).round(6)
          else
            issues << { code: :memory_available_unknown, component: "management" }
            row[:basis] = :unknown
            row[:available_bytes] = nil
            row[:used_bytes] = nil if row[:used_bytes] && row[:total_bytes] && row[:used_bytes] > row[:total_bytes]
          end
          row
        end

        # 将支持的内存单位转换为字节。
        def bytes(value, multiplier)
          number = Float(value) * multiplier
          number.round if number.finite? && number >= 0
        end
      end
    end
  end
end
