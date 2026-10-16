# frozen_string_literal: true

require_relative "snapshot"
require_relative "finding"
require "json"

module CtxChecker
  # 提供紧凑、可序列化的结果，独立保留采集覆盖率与故障信息。
  class Report
    attr_reader :snapshot, :findings, :counts, :commands

    # 冻结报告证据与检查结果，便于复现评估。
    def initialize(snapshot:, findings:)
      raise ArgumentError, "Report requires a snapshot" unless snapshot.is_a?(Snapshot)
      raise ArgumentError, "Report requires findings" unless findings.is_a?(Array) && findings.all?(Finding)
      @snapshot, @findings = snapshot, findings.dup.freeze
      @counts = %i[pass fail unknown not_applicable].to_h { |state| [ state, findings.count { |row| row.status == state } ] }.freeze
      @commands = CtxParser::Immutable.copy(command_results)
      freeze
    end

    # 判断所有已选事实是否都有完整证据支持。
    def complete? = counts[:unknown].zero? && snapshot.issues.empty? && snapshot.observations.values.all? { |row| %i[complete not_requested not_applicable].include?(row.status) }
    # 仅在覆盖充分且无失败检查时声明健康。
    def healthy? = complete? && counts[:pass].positive? && counts[:fail].zero?
    # 推导汇总状态，避免将证据缺失当作成功。
    def status = counts[:fail].positive? ? :fail : healthy? ? :pass : :unknown

    # 独立衡量已评估证据的覆盖情况，不与设备是否通过混淆。
    def coverage
      applicable = counts[:pass] + counts[:fail] + counts[:unknown]
      applicable.zero? ? 0.0 : ((counts[:pass] + counts[:fail]) * 100.0 / applicable).round(2)
    end

    # 返回公开的数据结构，并保留状态与诊断信息。
    def to_h = { status: status, complete: complete?, healthy: healthy?, coverage: coverage, counts: counts, commands: commands, snapshot: snapshot.to_h, findings: findings.map(&:to_h) }

    # 持久化摘要避免展开全部观测和测量值。
    def summary
      { status: status, complete: complete?, healthy: healthy?, coverage: coverage, counts: counts,
        target: snapshot.target, observed_at: snapshot.observed_at.iso8601(6), commands: commands,
        observations: snapshot.observations.transform_values do |row|
          details = { status: row.status, records: row.records.size, issues: row.issues }
          row.covered_scopes.empty? ? details : details.merge(covered_scopes: row.covered_scopes)
        end,
        issues: snapshot.issues, findings: findings.map { |row| row.to_h.reject { |key, _| %i[actual expected].include?(key) } } }
    end

    # 生成易读报告，区分已知故障与证据缺失。
    def to_text
      [ "Health: #{status} | coverage: #{coverage}% | pass=#{counts[:pass]} fail=#{counts[:fail]} unknown=#{counts[:unknown]} not_applicable=#{counts[:not_applicable]}",
        *commands.reject { |entry| entry[:status] == :complete }.map { |entry| command_text(entry) },
        *findings.map do |row|
          details = [ "#{row.status.to_s.ljust(14)} #{display(row.id)} #{display(row.entity)} (#{row.reason})" ]
          details << "actual=#{display(row.actual)}" unless row.actual.nil?
          details << "expected=#{display(row.expected)}" unless row.expected.nil?
          details.join(" | ")
        end ].join("\n")
    end

    private

    # 分别保留命令覆盖率、归并维度的健康与完整性。
    def command_results
      grouped = {}
      snapshot.observations.each_value do |observation|
        sources = observation.evidence.filter_map { |entry| entry[:command] }.uniq
        observation.evidence.each do |evidence|
          command = evidence[:command]
          next unless command

          issues = observation.issues.select { |issue| issue[:command] == command || !issue[:command] && sources.one? }
          state = issues.any? { |issue| issue[:skipped] } ? :skipped : evidence.fetch(:status, observation.status)
          entry = grouped[command] ||= { command: command, dimensions: {}, issues: [] }
          entry[:dimensions][observation.name] = command_status([ entry[:dimensions][observation.name], state ].compact)
          entry[:issues].concat(issues.map { |issue| issue.merge(dimension: observation.name) })
        end
      end
      grouped.each_value do |entry|
        entry[:status] = command_status(entry[:dimensions].values)
        entry[:issues].uniq!
      end
      grouped.values
    end

    # 共享查询可以同时产生一个有效视图和一个不可用视图。
    def command_status(states)
      unique = states.uniq
      return unique.first if unique.one?
      return :partial if unique.any? { |state| %i[complete partial].include?(state) }

      :failed
    end

    # 展示安全失败代码，不包含异常消息或原始响应。
    def command_text(entry)
      dimensions = entry[:dimensions].map { |name, state| "#{name}:#{state}" }.join(",")
      diagnostics = entry[:issues].map do |issue|
        code = [ issue[:stage], issue[:code] ].compact.join(":")
        issue[:error_type] ? "#{code} (#{issue[:error_type]})" : code
      end.uniq
      [ "Command: #{entry[:status]}", display(entry[:command]), "dimensions=#{dimensions}", *diagnostics.map { |value| display(value) } ].join(" | ")
    end

    # 结构化测量保持可读，同时限制报告单元格的换行与长度。
    def display(value)
      text = value.is_a?(String) ? value : JSON.generate(value)
      text = text.gsub(/[\x00-\x1f\x7f]/) { |character| format("\\u%04x", character.ord) }
      text.length > 512 ? "#{text[0, 509]}..." : text
    end
  end
end
