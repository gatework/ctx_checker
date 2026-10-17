# frozen_string_literal: true

module CtxChecker
  module Parsers
    # 解析期只保留有界诊断样本；省略数量仍进入结果，不能将截断当作完整。
    class Diagnostics < Array
      MAX_SAMPLES = 128

      # 每个解析视图独立拥有样本和省略计数。
      def initialize
        super
        @samples = 0
        @summary = nil
      end

      # 合并多个来源时累加原有省略数，不把摘要误计为一条普通诊断。
      def <<(issue)
        if issue[:code] == :diagnostics_truncated
          omit(issue[:count])
        elsif @samples < MAX_SAMPLES
          insert(@samples, issue)
          @samples += 1
        else
          omit(1)
        end
        self
      end

      # 跨视图合并仍经过同一预算，不恢复已省略的诊断。
      def concat(issues)
        issues.each { |issue| self << issue }
        self
      end

      private

      # 原地更新本集合持有的摘要，避免每次省略都创建一个对象。
      def omit(count)
        unless @summary
          @summary = { code: :diagnostics_truncated, count: 0 }
          self[size] = @summary
        end
        @summary[:count] += count
      end
    end
  end
end
