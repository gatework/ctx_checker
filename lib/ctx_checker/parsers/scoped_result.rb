# frozen_string_literal: true

require "ctx_parser/result"
require "ctx_parser/immutable"

module CtxChecker
  module Parsers
    # 运行表即使没有实体，也可证明已枚举的作用域。
    class ScopedResult < CtxParser::Result
      attr_reader :covered_scopes

      # 冻结各作用域证据，不合并无关的观测结果。
      def initialize(covered_scopes: [], **attributes)
        @covered_scopes = CtxParser::Immutable.copy(covered_scopes)
        super(**attributes)
      end

      # 值相等、序列化与替换操作均保留覆盖范围语义。
      def to_h(&block)
        attributes = { status: status, records: records, issues: issues, covered_scopes: covered_scopes }
        block ? attributes.to_h(&block) : attributes
      end
      # 向 Ruby 模式匹配提供结果字段与已覆盖作用域。
      def deconstruct_keys(keys) = keys ? to_h.slice(*keys) : to_h
      # 创建新的不可变结果，同时保留未修改的作用域证据。
      def with(**changes) = self.class.new(**to_h.merge(changes))
      # 比较全部结果字段，包括明确的作用域覆盖范围。
      def ==(other) = other.instance_of?(self.class) && to_h == other.to_h
      # 比较结果值时同时比较已覆盖作用域。
      def eql?(other) = other.instance_of?(self.class) && to_h.eql?(other.to_h)
      # 按与相等判断一致的字段和作用域计算哈希。
      def hash = [ self.class, to_h ].hash
    end
  end
end
