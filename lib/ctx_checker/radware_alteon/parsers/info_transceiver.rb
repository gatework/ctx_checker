# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 模块只有测量值而无阈值时，不能证明光学健康。
      class InfoTransceiver < CtxChecker::Parsers::Base
        HEADER = /\APort\s+Temperature\s+Voltage\s+Current\s+Optical\s+Optical\s+Vendor Name\s+Vendor PN\s+VendorRev\s+VendorsN\s+VendorDateCode\z/i
        LABELS = /\A\(Celsius\)\s+\(Volts\)\s+\(mA\)\s+Tx Power\s+Rx Power\s+\(yymmdd\)\z/i
        UNITS = /\A\(dBm\)\s+\(dBm\)\z/i
        ROW = /\A(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\S+(?:\s+\S+){4,}\z/
        NUMBER = /\A[+-]?\d+(?:\.\d+)?\z/

        private

        # 指定光学方向或单位前，先校验多行表头。
        def parse_output(text, complete:)
          rows, issues, headings = [], diagnostics, []
          clean(text).each_line("\n") do |raw|
            line = raw.strip
            next if line.empty? || /\A[-\s]+\z/.match?(line)

            if HEADER.match?(line) || LABELS.match?(line) || UNITS.match?(line)
              heading = HEADER.match?(line) ? :header : LABELS.match?(line) ? :labels : :units
              issues << { code: :duplicate_optics_header } if headings.include?(heading)
              headings << heading
            elsif headings == %i[header labels units] && (match = /\A(\d+)\s+NA\z/i.match(line)) && match[1].to_i.positive?
              rows.concat(measurements(match[1], nil, nil))
            elsif headings == %i[header labels units] && (match = ROW.match(line)) && match[1].to_i.positive?
              values = match.captures[1, 5]
              unless values.all? { |value| value.casecmp?("NA") || !number(value).nil? }
                issues << { code: :invalid_optics_value, interface: "port#{Integer(match[1], 10)}" }
              end
              rows.concat(measurements(match[1], number(values[3]), number(values[4])))
            else
              issues << { code: :unrecognized_optics_line }
              headings = [] if /\APort\b|\A\(|Optical|Power/.match?(line)
            end
          end
          issues << { code: :optics_header_missing } unless headings == %i[header labels units]
          issues << { code: :optics_measurements_missing } if rows.empty?
          build_result(rows, complete: complete, recognized: headings.include?(:header), issues: issues,
            identity: %i[interface lane metric])
        end

        # 长、短 NA 行均保留模块是否存在及 DOM 是否支持的未知状态。
        def measurements(port, tx, rx)
          measured = !tx.nil? || !rx.nil?
          %i[tx_power rx_power].zip([ tx, rx ]).map do |metric, value|
            { interface: "port#{Integer(port, 10)}", lane: nil, metric: metric, value: value, unit: :dbm,
              low_alarm: nil, low_warning: nil, high_warning: nil, high_alarm: nil, alarm: :unknown,
              present: measured ? true : nil, dom_supported: measured ? true : nil, applicable: nil }
          end
        end

        # 保留有限 dBm 值，不将不可用单元格视为零。
        def number(value)
          return unless NUMBER.match?(value)

          parsed = Float(value)
          parsed if parsed.finite?
        end
      end
    end
  end
end
