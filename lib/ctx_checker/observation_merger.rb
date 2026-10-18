# frozen_string_literal: true

require_relative "observation"
require "ctx_parser/records"

module CtxChecker
  # 组合独立命令证据，不拼接不相容的 CLI 语法正文。
  class ObservationMerger
    # 归并已声明的命令证据，不丢失来源失败或身份歧义。
    def self.call(name, observations, commands:, required_metrics: [])
      unless observations.is_a?(Array) && observations.all? do |observation|
          observation.is_a?(Observation) && observation.name == name && observation.status != :not_requested
        end
        raise ArgumentError, "Command observations must share a requested dimension"
      end
      sources = observations.map do |observation|
        source = observation.evidence.map { |entry| entry[:command] }.compact.uniq
        raise ArgumentError, "Observation must identify one declared source command" unless source.one? && commands.include?(source.first)
        source.first
      end
      raise ArgumentError, "Duplicate source command" unless sources.uniq == sources

      if observations.any? && observations.all? { |observation| observation.status == :not_applicable } && (commands - sources).empty?
        return Observation.new(name: name, status: :not_applicable,
          issues: observations.flat_map(&:issues).uniq, evidence: observations.flat_map(&:evidence))
      end

      issues = observations.zip(sources).flat_map do |observation, command|
        observation.issues.reject { |issue| issue[:code] == :incomplete_command_set }.map { |issue| issue.merge(command: command) }
      end
      if observations.any? { |observation| observation.status == :partial && observation.issues.empty? }
        issues << { code: :incomplete_command_output }
      end
      missing = commands - sources
      issues << { code: :incomplete_command_set, count: missing.size } if missing.any?
      records = observations.flat_map do |observation|
        observation.records.map do |record|
          if %i[counters device_counters].include?(name) && record[:sampled_at].nil? && observation.observed_at
            record.merge(sampled_at: observation.observed_at.iso8601(6))
          else
            record
          end
        end
      end
      grouped = CtxParser::Records.new(records, identity: Observation::IDENTITIES.fetch(name))
      covered_scopes = observations.flat_map(&:covered_scopes).uniq
      if grouped.duplicates?
        issues << { code: :duplicate_identity, count: grouped.duplicate_identity_count }
        records = grouped.unambiguous.dup
        # 隔离的对等体实际已被观察到，因此移除后不能再据其作用域证明缺失。
        ambiguous = grouped.first_occurrences - grouped.unambiguous
        covered_scopes = covered_scopes.reject do |scope|
          ambiguous.any? { |row| scope.all? { |key, value| row[key].nil? || row[key] == value } }
        end
      end
      if name == :counters && required_metrics.any?
        # 补齐缺失指标的未知占位，不把独立方向查询失败解释为零错误。
        records.group_by { |row| row[:interface] }.each do |interface, rows|
          absent = required_metrics - rows.map { |row| row[:metric] }
          next if absent.empty?
          issues << { code: :counter_metrics_missing, interface: interface, metrics: absent }
          records.concat(absent.map { |metric| { interface: interface, metric: metric, value: nil } })
        end
      end
      unavailable = observations.all? { |observation| %i[failed unsupported].include?(observation.status) }
      # 有成功事实时降为部分完整，而非让同级脚本失败抹除整份维度结果。
      status = if unavailable && records.empty?
        observations.any? && observations.all? { |observation| observation.status == :unsupported } && missing.empty? ? :unsupported : :failed
      elsif issues.any? || observations.any? { |observation| %i[failed unsupported].include?(observation.status) }
        :partial
      else
        :complete
      end
      if name == :aggregation && status == :complete && records.empty?
        status = :not_applicable
        issues << { code: :aggregation_not_configured }
      end
      Observation.new(name: name, status: status, records: records, issues: issues.uniq,
        covered_scopes: covered_scopes, evidence: observations.flat_map(&:evidence))
    end
  end
end
