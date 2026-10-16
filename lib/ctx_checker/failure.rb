# frozen_string_literal: true

require_relative "observation"

module CtxChecker
  # 运行失败仅展示阶段与安全异常类型，不包含异常消息或原始回显。
  module Failure
    # 构建单个失败维度，保留安全错误元数据及可追溯的命令证据。
    def self.observation(name, code:, stage:, command:, error: nil, error_type: nil, evidence: [], skipped: false)
      issue = { code: code, stage: stage, command: command, skipped: skipped }
      issue[:error_type] = error ? self.error_type(error) : error_type if error || error_type
      entries = evidence.empty? ? [ {} ] : evidence
      Observation.new(name: name, status: :failed, issues: [ issue ],
        evidence: entries.map { |entry| entry.merge(command: command, status: :failed) })
    end

    # 匿名异常仍使用安全类别，不输出对象检查内容。
    def self.error_type(error)
      name = error.class.name
      name.is_a?(String) && Observation::ERROR_TYPE_PATTERN.match?(name) ? name : "StandardError"
    end
    private_class_method :error_type
  end
end
