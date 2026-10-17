# frozen_string_literal: true

require "date"
require_relative "../../parsers/base"
require "ctx_parser/results"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 累计 NTP 请求与更新次数不能证明当前同步状态。
      class StatsSysNtp < CtxChecker::Parsers::Base
        COUNTERS = { "Requests Sent" => "requests_sent", "Responses Received" => "responses_received", "Updates" => "updates" }.freeze

        private

        # 计数器完整性独立于当前 NTP 状态是否可用。
        def parse_output(text, complete:)
          source = clean(text)
          rows, headers, sections, time_fields = [], 0, [], []
          counter_issues, ntp_issues, section = diagnostics, diagnostics, nil
          source.each_line.with_index(1) do |raw, number|
            line = raw.strip
            next if line.empty? || /\A-+\z/.match?(line)

            if line == "NTP server statistics:"
              headers += 1
            elsif (match = /\A(Primary|Secondary) Server:\z/.match(line))
              section = match[1].downcase
              sections << section
            elsif (match = /\A(Requests Sent|Responses Received|Updates):\s*(.*?)\z/.match(line))
              row = counter(section, match[1], match[2], number, counter_issues)
              rows << row if row
            elsif /\ALast update based on response from (?:primary|secondary) server\.\z/.match?(line)
              time_fields << :server
            elsif (match = /\A(Last update time|Current system time):\s*(.*?)\z/.match(line))
              field = match[1] == "Last update time" ? :last_update : :current_time
              time_fields << field
              ntp_issues << { code: :invalid_ntp_time, field: field, line: number } unless valid_time?(match[2])
            else
              issue = { code: :unrecognized_ntp_line, line: number }
              counter_issues << issue
              ntp_issues << issue
            end
          end
          counter_issues << { code: :missing_ntp_statistics_header } unless headers == 1
          %w[primary secondary].each do |peer|
            counter_issues << { code: :incomplete_ntp_counter_section, component: peer } unless sections.count(peer) == 1 && rows.count { |row| row[:component] == "ntp/#{peer}" } == COUNTERS.size
          end
          ntp_issues << { code: :ntp_system_status_unavailable }
          ntp_issues << { code: :ntp_last_sync_offset_unknown } if time_fields.include?(:last_update)
          %i[server last_update current_time].each do |field|
            ntp_issues << { code: :ambiguous_ntp_time_field, field: field, count: time_fields.count(field) } unless time_fields.count(field) == 1
          end
          ntp_rows = headers.positive? ? [ { component: "system", synchronized: nil, last_sync_status: :unknown, last_sync_at: nil } ] : []
          CtxParser::Results.new(by_dimension: {
            ntp: build_result(ntp_rows, complete: complete, recognized: headers.positive?, issues: ntp_issues, identity: [ :component ]),
            device_counters: build_result(rows, complete: complete, recognized: rows.any?, issues: counter_issues, identity: %i[component metric])
          })
        end

        # 仅暴露具名整数计数器，不通过运算推导故障或重置次数。
        def counter(section, label, raw, number, issues)
          unless section
            issues << { code: :ntp_counter_section_missing, line: number }
            return
          end
          value = /\A\d+\z/.match?(raw) ? Integer(raw, 10) : nil
          issues << { code: :invalid_ntp_counter, line: number } unless value
          { component: "ntp/#{section}", metric: COUNTERS.fetch(label), category: :informational,
            value: value, discontinuity: nil, sampled_at: nil }
        end

        # 校验本地时间戳，不虚构时区偏移或同步尝试结果。
        def valid_time?(text)
          match = /\A(\d{2}:\d{2}:\d{2}) (Sun|Mon|Tue|Wed|Thu|Fri|Sat) ([A-Z][a-z]{2}) (\d{1,2}), (\d{4})\z/.match(text)
          return false unless match && match[1].split(":").map(&:to_i).zip([ 24, 60, 60 ]).all? { |value, limit| value < limit }

          date = Date.strptime("#{match[3]} #{match[4]} #{match[5]}", "%b %d %Y")
          Date::ABBR_DAYNAMES[date.wday] == match[2]
        rescue ArgumentError
          false
        end
      end
    end
  end
end
