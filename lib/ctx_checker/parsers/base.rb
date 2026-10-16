# frozen_string_literal: true

require "ctx_parser"
require "ctx_parser/input"
require_relative "interface_names"
require_relative "scoped_result"

module CtxChecker
  module Parsers
    # 共享文本边界与完整性规则，不在厂商解析器中嵌入健康策略。
    class Base < CtxParser::Parser
      MAX_BYTES = 16 * 1024 * 1024

      private

      # 从归一化观测记录中移除不支持的数据。
      def clean(text)
        @issues = []
        @unsupported = false
        source = CtxParser::Input.text(text, encoding: :transcode, newlines: :lf, max_bytes: MAX_BYTES)
        source.each_line.with_index(1) do |line, number|
          if /\A\s*(?:(?:%\s*)?(?:Error:\s*)?(?:Invalid (?:input|command|syntax)|Unrecognized command|Unknown command|command not (?:found|supported)|not supported on this|syntax error)|\^-+\s*unrecognized keyword\b)/i.match?(line)
            @unsupported = true
            @issues << { code: :unsupported_command, line: number }
          elsif /\A\s*(?:%\s*(?:Error|Incomplete|Ambiguous)|Error:|Permission denied|Insufficient privilege|\^-+\s*(?:incomplete command|ambiguous command|error\b))/i.match?(line)
            @issues << { code: :command_error, line: number }
          elsif /--\s*More\s*--|----\s*More\s*----|Press (?:any key|ENTER|<SPACE>)/i.match?(line)
            @issues << { code: :paginated_output, line: number }
          end
        end
        source
      end

      # 隔离身份冲突，保留无歧义记录并降低覆盖完整性。
      def build_result(records, complete:, recognized:, issues: [], identity: nil, covered_scopes: [])
        problems = Array(@issues) + issues
        if identity
          grouped = CtxParser::Records.new(records, identity: identity)
          if grouped.duplicates?
            problems << { code: :duplicate_identity, count: grouped.duplicate_identity_count }
            records = grouped.unambiguous
          end
        end
        problems << { code: :unrecognized_output } unless recognized
        problems << { code: :incomplete_output } unless complete
        status = if @unsupported
          records = []
          :unsupported
        elsif Array(@issues).any? { |issue| issue[:code] == :command_error }
          records = []
          :failed
        elsif !recognized && records.empty?
          :failed
        elsif problems.any?
          :partial
        else
          :complete
        end
        if covered_scopes.any?
          ScopedResult.new(status: status, records: records, issues: problems.uniq,
            covered_scopes: status == :complete ? covered_scopes.uniq : [])
        else
          CtxParser::Result.new(status: status, records: records, issues: problems.uniq)
        end
      end
    end
  end
end
