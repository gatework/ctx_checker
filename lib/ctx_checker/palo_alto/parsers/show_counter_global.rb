# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module PaloAlto
    module Parsers
      # 数值自数据平面重启后累计；CLI 速率采样由外部调用方管理。
      class ShowCounterGlobal < CtxChecker::Parsers::Base
        CATEGORIES = { "info" => :informational, "warn" => :error, "error" => :error, "drop" => :discard }.freeze
        # 安全策略执行与设备转发故障区分处理。
        METRIC_CATEGORIES = { "flow_policy_deny" => :policy }.freeze

        private

        # 解析 show counter global，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows, totals, issues = [], [], diagnostics
          title, header = false, false
          source.each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            if line == "Global counters:"
              title = true
            elsif line.match?(/\Aname\s+value\s+rate\s+severity\s+category\s+aspect\s+description\z/)
              header = true
            elsif (match = /\ATotal counters shown:\s*(\d+)\z/.match(line))
              totals << Integer(match[1], 10)
            elsif line.empty? || line.match?(/\A-+\z/) || line.match?(/\AElapsed time since last sampling:\s*\d+(?:\.\d+)? seconds\z/)
              next
            elsif header && (match = /\A([a-zA-Z][a-zA-Z0-9_]*)\s+(\d+)\s+\d+\s+(info|warn|error|drop)\s+(\S+)\s+(\S+)\s+.+\z/.match(line))
              rows << { component: "dataplane/#{match[4]}/#{match[5]}", metric: match[1], category: METRIC_CATEGORIES.fetch(match[1], CATEGORIES.fetch(match[3])),
                value: Integer(match[2], 10), discontinuity: nil }
            else
              issues << { code: :unrecognized_counter_row, line: number }
            end
          end
          if !totals.one? || totals.first != rows.size
            issues << { code: :counter_total_mismatch, observed: rows.size, expected: totals.one? ? totals.first : nil }
          end
          recognized = title && header && (rows.any? || totals == [ 0 ])
          build_result(rows, complete: complete, recognized: recognized, issues: issues, identity: %i[component metric])
        end
      end
    end
  end
end
