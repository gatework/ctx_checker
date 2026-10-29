# frozen_string_literal: true

require "ctx_parser"
require "ctx_parser/input"
require_relative "interface_names"
require_relative "diagnostics"

module CtxChecker
  module Parsers
    # 共享文本边界与完整性规则，不在厂商解析器中嵌入健康策略。
    class Base < CtxParser::Parser
      MAX_BYTES = 16 * 1024 * 1024

      private

      # 各命令和共享视图使用相同的诊断预算。
      def diagnostics = Diagnostics.new

      # 从归一化观测记录中移除不支持的数据。
      def clean(text)
        @issues = diagnostics
        @unsupported = false
        @command_failed = false
        source = CtxParser::Input.text(text, encoding: :transcode, newlines: :lf, max_bytes: MAX_BYTES)
        source.each_line("\n").with_index(1) do |line, number|
          if /\A\s*(?:(?:%\s*)?(?:Error:\s*)?(?:Invalid (?:input|command|syntax)|Unrecognized command|Unknown command|command not (?:found|supported)|not supported on this|syntax error)|\^-+\s*unrecognized keyword\b)/i.match?(line)
            @unsupported = true
            @issues << { code: :unsupported_command, line: number }
          elsif /\A\s*(?:%\s*(?:Error|Incomplete|Ambiguous)|Error:|Permission denied|Insufficient privilege|\^-+\s*(?:incomplete command|ambiguous command|error\b))/i.match?(line)
            @command_failed = true
            @issues << { code: :command_error, line: number }
          elsif /--\s*More\s*--|----\s*More\s*----|Press (?:any key|ENTER|<SPACE>)/i.match?(line)
            @issues << { code: :paginated_output, line: number }
          end
        end
        # 明确失败的命令不会保留记录，无需再次逐行解析其错误正文。
        @unsupported || @command_failed ? "" : source
      end

      # 隔离身份冲突，保留无歧义记录并降低覆盖完整性。
      def build_result(records, complete:, recognized:, issues: [], identity: nil, covered_scopes: [])
        problems = diagnostics.concat(Array(@issues)).concat(issues)
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
        elsif @command_failed
          records = []
          :failed
        elsif !recognized && records.empty?
          :failed
        elsif problems.any?
          :partial
        else
          :complete
        end
        CtxParser::Result.new(status: status, records: records, issues: problems.uniq,
          covered_scopes: status == :complete ? covered_scopes.uniq : [])
      end
    end
  end
end
