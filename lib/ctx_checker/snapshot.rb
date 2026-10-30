# frozen_string_literal: true

require "forwardable"
require "ctx_runner/snapshot"
require_relative "observation"

module CtxChecker
  # 领域校验观测与诊断；通用快照负责身份、时间及采集完整性。
  class Snapshot
    include CtxRunner::Document::Value
    extend Forwardable
    def_delegators :@snapshot, :target, :observed_at, :observations, :issues, :collection_status,
      :observation, :records, :same_target?, :complete?, :to_h

    def initialize(target:, observed_at:, observations:, issues: [])
      target = CtxRunner::Target.coerce(target).to_h
      raise ArgumentError, "Checker target requires a platform" unless target[:platform].is_a?(String)
      unless observations.is_a?(Hash) && observations.all? { |name, row| Observation::NAMES.include?(name) && row.is_a?(Observation) && row.name == name }
        raise ArgumentError, "Snapshot observations must match their dimensions"
      end
      unless issues.is_a?(Array) && issues.all? { |issue| Observation.valid_issue?(issue) }
        raise ArgumentError, "Snapshot issues require safe codes"
      end
      selected = Observation::NAMES.to_h { |name| [ name, observations.fetch(name) { Observation.new(name: name, status: :not_requested) } ] }
      @snapshot = CtxRunner::Snapshot.new(target: target, observations: selected, observed_at: observed_at,
        names: Observation::NAMES, issues: issues)
      freeze
    end

    def inspect = "#<#{self.class.name} collection_status=#{collection_status}>"
    alias to_s inspect
    def pretty_print(printer) = printer.text(inspect)
  end
end
