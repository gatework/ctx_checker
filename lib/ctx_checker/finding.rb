# frozen_string_literal: true

require_relative "observation"

module CtxChecker
  # 单条检查结果包含原因说明；严重级别不能代替实际结果状态。
  Finding = Data.define(:id, :dimension, :entity, :status, :severity, :reason, :actual, :expected) do
    # 独立校验并冻结检查结果及其说明，不由严重级别推断状态。
    def initialize(id:, dimension:, entity: nil, status:, severity: :info, reason:, actual: nil, expected: nil)
      raise ArgumentError, "Invalid finding dimension" unless Observation::NAMES.include?(dimension) || dimension == :collection
      raise ArgumentError, "Invalid finding status" unless %i[pass fail unknown not_applicable].include?(status)
      raise ArgumentError, "Invalid finding severity" unless %i[info warning critical].include?(severity)
      unless id.is_a?(String) && /\A[a-z][a-z0-9_.]*\z/.match?(id) && reason.is_a?(Symbol) && /\A[a-z][a-z0-9_]*\z/.match?(reason.to_s)
        raise ArgumentError, "Findings require an ID and reason code"
      end
      super(**CtxParser::Immutable.copy(id: id, dimension: dimension, entity: entity, status: status, severity: severity, reason: reason, actual: actual, expected: expected))
    end
  end
end
