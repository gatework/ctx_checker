# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 设备 RAM 与进程虚拟内存、RSS 属于不同内存作用域。
      class StatsMpMem < CtxChecker::Parsers::Base
        LABELS = { "Total device" => :total, "Free device" => :free, "Cached (Linux)" => :cached,
          "MP Virtual Memory" => :virtual, "MP Resident(RSS Linux) Memory" => :rss }.freeze
        UNITS = { "KB" => 1024, "MB" => 1024**2, "GB" => 1024**3 }.freeze

        private

        # 扣除明确报告的 Linux 缓存；原始进程数值仅作为来源证据保留。
        def parse_output(text, complete:)
          values, headers = Hash.new { |hash, key| hash[key] = [] }, 0
          clean(text).each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            if line == "Memory stats:"
              headers += 1
            elsif (match = /\A(.+?):\s*(\S+)\s+(\S+)\z/.match(line))
              label = LABELS[match[1].gsub(/\s+/, " ")]
              unless label
                @issues << { code: :unrecognized_memory_line, line: number }
                next
              end
              value = /\A\d+(?:\.\d+)?\z/.match?(match[2]) ? Float(match[2], exception: false) : nil
              multiplier = UNITS[match[3]]
              amount = value && multiplier && value * multiplier
              valid = amount&.finite?
              @issues << { code: :invalid_memory_measurement, field: label } unless valid
              values[label] << (valid ? amount.round : nil)
            elsif !line.empty? && !/\A-+\z/.match?(line)
              @issues << { code: :unrecognized_memory_line, line: number }
            end
          end
          @issues << { code: :memory_header_invalid } unless headers == 1
          duplicates = values.count { |_name, readings| readings.size > 1 }
          @issues << { code: :duplicate_memory_measurement, count: duplicates } if duplicates.positive?
          total, free, cached = %i[total free cached].map { |key| values[key].one? ? values[key].first : nil }
          valid = total&.positive? && free && cached && free + cached <= total
          @issues << { code: :memory_available_unknown } unless valid
          rows = if %i[total free cached].any? { |key| values[key].any? }
            [ { component: "system", scope: "physical", total_bytes: total, free_bytes: free,
              used_bytes: valid ? total - free - cached : nil, available_bytes: valid ? free + cached : nil,
              utilization: valid ? (total - free - cached).fdiv(total) * 100 : nil,
              basis: valid ? :used_minus_cache : :unknown } ]
          else
            []
          end
          build_result(rows, complete: complete, recognized: rows.any?, identity: %i[component scope])
        end
      end
    end
  end
end
