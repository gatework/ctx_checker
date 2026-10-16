# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module CiscoIos
    module Parsers
      # 分别保留 IOS 各内存分配池，并使用精确字节数核算。
      class ShowMemoryStatistics < CtxChecker::Parsers::Base
        private

        # 解析 show memory statistics，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          records, issues = [], []
          clean(text).each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty? || /\AHead\s+Total\(b\)/.match?(line) || /\ATracekey\s*:\s*[\da-f#]+\z/i.match?(line)

            match = /\A(.+?)\s+Pool\s+Total:\s*(\d+)\s+Used:\s*(\d+)\s+Free:\s*(\d+)\z/i.match(line) ||
              /\A(.+?)\s+[0-9a-f]+\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+\s+\d+\z/i.match(line)
            unless match
              issues << { code: :unparsed_row, line: number }
              next
            end
            total, used, free = match.captures.drop(1).map { |value| Integer(value, 10) }
            consistent = total.positive? && used + free == total
            issues << { code: :inconsistent_memory_totals, line: number } unless consistent
            records << { component: match[1], scope: "ios_memory_pool", total_bytes: total, used_bytes: used,
              free_bytes: free, available_bytes: nil, utilization: consistent ? used.fdiv(total) * 100 : nil, basis: :used_total }
          end
          build_result(records, complete: complete, recognized: records.any?, issues: issues, identity: %i[component scope])
        end
      end
    end
  end
end
