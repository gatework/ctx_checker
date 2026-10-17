# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "system_values"

module CtxChecker
  module CiscoIos
    module Parsers
      # IOS 进程 CPU 包含中断工作量，不代表 IOS-XE 的 Linux 整机 CPU。
      class ShowProcessesCpu < CtxChecker::Parsers::Base
        include SystemValues

        private

        # 解析 show processes cpu，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          records, issues = [], diagnostics
          recognized = false
          clean(text).each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty?

            if (match = /\ACPU utilization for five seconds:\s*([^%]+)%\/([^%]+)%; one minute:\s*([^%]+)%; five minutes:\s*([^%]+)%\z/i.match(line))
              recognized = true
              [ [ 5, match[1], match[2] ], [ 60, match[3], nil ], [ 300, match[4], nil ] ].each do |window, value, interrupt|
                utilization = percentage(value)
                interrupt_utilization = percentage(interrupt)
                valid = utilization && (!interrupt || interrupt_utilization && interrupt_utilization <= utilization)
                issues << { code: :invalid_cpu_value, line: number } unless valid
                records << { component: "processor", scope: "ios_processes", window_seconds: window,
                  utilization: utilization, interrupt_utilization: interrupt_utilization }
              end
            elsif /\A(?:PID\s+Runtime|\d+\s+\d+\s+\d+\s+\d+\s+[\d.]+%\s+[\d.]+%\s+[\d.]+%\s+\d+\s+)/.match?(line)
              next
            else
              issues << unparsed(number)
            end
          end
          build_result(records, complete: complete, recognized: recognized, issues: issues,
            identity: %i[component scope window_seconds])
        end
      end
    end
  end
end
