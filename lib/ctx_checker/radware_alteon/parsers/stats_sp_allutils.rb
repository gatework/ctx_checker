# frozen_string_literal: true

require_relative "../../parsers/base"
require "ctx_parser/results"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 各 SP 时间窗与内存章节独立保留覆盖诊断。
      class StatsSpAllutils < CtxChecker::Parsers::Base
        private

        # 校验回显的 SP 数量及汇总图，不混用 CPU 和内存数据。
        def parse_output(text, complete:)
          rows = { cpu: [], memory: [] }
          issues = rows.transform_values { diagnostics }
          sections, current = [], nil
          clean(text).each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            if (match = /\ASPs CPU utilization percentage for (\d+) sec sampling\s*:\z/.match(line))
              current = section(:cpu, match[1].to_i)
              sections << current
            elsif line == "SPs memory percentage:"
              current = section(:memory, nil)
              sections << current
            elsif line.empty? || /\A-+\z/.match?(line)
              next
            elsif current
              parse_section_line(line, number, current, rows, issues)
            else
              issues.each_value { |items| items << { code: :unrecognized_sp_line, line: number } }
            end
          end
          sections.each { |item| validate_section(item, issues.fetch(item[:dimension])) }
          validate_sections(sections, issues)
          CtxParser::Results.new(by_dimension: rows.to_h do |dimension, records|
            identity = dimension == :cpu ? %i[component scope window_seconds] : %i[component scope]
            [ dimension, build_result(records, complete: complete, recognized: records.any?, issues: issues.fetch(dimension), identity: identity) ]
          end)
        end

        # 分别跟踪各章节，不用单个命令成功标志代替全部章节状态。
        def section(dimension, seconds)
          { dimension: dimension, seconds: seconds, ids: [], summaries: [], graphs: [] }
        end

        # 柱状图仅作展示上下文，明确百分比字段才是数值来源。
        def parse_section_line(line, number, current, rows, issues)
          errors = issues.fetch(current[:dimension])
          if (match = /\ASP\s+(\d+)\s*:\s*\[[#.]+\]\s+(\S+)\z/.match(line))
            id = match[1].to_i
            value = percentage(match[2], errors, number)
            current[:ids] << id
            errors << { code: :invalid_sp_identity, line: number } if id.zero?
            base = { component: "SP#{id}", scope: "service_plane", utilization: id.positive? ? value : nil }
            record = current[:dimension] == :cpu ? base.merge(window_seconds: current[:seconds]) : base.merge(basis: :used_total)
            rows.fetch(current[:dimension]) << record
          elsif (match = /\AAverage\s*:\s*(\S+)\s+\(total (\d+) sp's\)\z/.match(line))
            current[:summaries] << { value: percentage(match[1], errors, number), count: match[2].to_i }
          elsif (match = /\A\[[#.]+\]\s+(\S+)\z/.match(line))
            current[:graphs] << percentage(match[1], errors, number)
          else
            errors << { code: :unrecognized_sp_line, line: number }
          end
        end

        # 数值缺失、非有限值或超过 100 的百分比不能变成零。
        def percentage(text, issues, number)
          value = /\A\d+(?:\.\d+)?%\z/.match?(text) ? Float(text.delete_suffix("%"), exception: false) : nil
          return value if value&.finite? && value.between?(0, 100)
          issues << { code: :invalid_sp_measurement, line: number }
          nil
        end

        # 要求汇总完整，且所有声明的 SP 身份均存在且不重复。
        def validate_section(item, issues)
          valid = item[:summaries].one? && item[:graphs].one?
          summary = item[:summaries].first
          valid &&= summary[:value] && summary[:count].positive? && summary[:count] == item[:ids].uniq.size &&
            item[:ids].uniq.size == item[:ids].size && summary[:value] == item[:graphs].first
          issues << { code: :incomplete_sp_section, window_seconds: item[:seconds] } unless valid
        end

        # CPU 时间窗或内存表缺失仅影响其各自结果视图。
        def validate_sections(sections, issues)
          cpu = sections.select { |item| item[:dimension] == :cpu }
          memory = sections.select { |item| item[:dimension] == :memory }
          unless cpu.map { |item| item[:seconds] }.sort == [ 4, 64 ]
            issues[:cpu] << { code: :incomplete_sp_cpu_windows }
          end
          issues[:memory] << { code: :incomplete_sp_memory_sections } unless memory.one?
          cpu.each_cons(2) do |first, last|
            issues[:cpu] << { code: :inconsistent_sp_identities } unless first[:ids].sort == last[:ids].sort
          end
        end
      end
    end
  end
end
