# frozen_string_literal: true

require "time"
require_relative "observation"

module CtxChecker
  # 快照绑定目标及采样时刻；缺少的维度明确保持未请求。
  class Snapshot
    attr_reader :target, :observed_at, :observations, :issues

    # 冻结设备身份、观测结果与采样时间。
    def initialize(target:, observed_at:, observations:, issues: [])
      unless target.is_a?(Hash) && (target.keys - %i[host platform model software_version id]).empty? &&
          %i[host platform].all? { |key| target[key].is_a?(String) && !target[key].strip.empty? } &&
          target.all? { |key, value| value.nil? || value.is_a?(String) && !/[\x00-\x1f\x7f]/.match?(value) || key == :id && value.is_a?(Integer) && value >= 0 }
        raise ArgumentError, "Target requires host and platform without connection secrets"
      end
      unless observations.is_a?(Hash) && observations.all? { |name, row| Observation::NAMES.include?(name) && row.is_a?(Observation) && row.name == name }
        raise ArgumentError, "Snapshot observations must match their dimensions"
      end
      unless issues.is_a?(Array) && issues.all? { |issue| Observation.valid_issue?(issue) }
        raise ArgumentError, "Snapshot issues require safe codes"
      end
      @observed_at = case observed_at
      when Time then observed_at.getutc.freeze
      when String
        raise ArgumentError, "Observation time requires a valid date and explicit UTC offset" unless SystemFields.timestamp?(observed_at)
        Time.iso8601(observed_at).getutc.freeze
      else raise ArgumentError, "Observation time must be Time or ISO8601"
      end
      @target = CtxParser::Immutable.copy(target)
      @issues = CtxParser::Immutable.copy(issues)
      @observations = Observation::NAMES.to_h { |name| [ name, observations.fetch(name) { Observation.new(name: name, status: :not_requested) } ] }.freeze
      freeze
    end

    # 返回请求的观测，不虚构不可用记录。
    def observation(name) = observations.fetch(name)
    # 检查两次采样是否指向同一设备与平台。
    def same_target?(other) = other.is_a?(Snapshot) && %i[host platform id].all? { |key| target[key] == other.target[key] }
    # 返回公开的数据结构，并保留状态与诊断信息。
    def to_h = { target: target, observed_at: observed_at.iso8601(6), observations: observations.transform_values(&:to_h), issues: issues }
    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class} observations=#{observations.size}>"
  end
end
