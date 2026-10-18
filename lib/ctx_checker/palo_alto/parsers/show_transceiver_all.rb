# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module PaloAlto
    module Parsers
      # 汇总功率使用 mW；零和 N/A 不能转换为有限的 dBm 读数。
      class ShowTransceiverAll < CtxChecker::Parsers::Base
        NUMBER = /(?:\d+(?:\.\d+)?|n\/a)/i

        private

        # 解析 show transceiver all，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues, header = [], diagnostics, false
          text.each_line("\n") do |raw|
            line = raw.strip
            if /\APort\s+Temperature\s+Voltage\s+Current\s+Tx Power\s+Rx Power\z/i.match?(line)
              header = true
            elsif (match = /\A(ethernet\d+\/\d+)\s+#{NUMBER}(?:\s+C)?\s+#{NUMBER}(?:\s+V)?\s+#{NUMBER}(?:\s+mA)?\s+(#{NUMBER})(?:\s+mW)?\s+(#{NUMBER})(?:\s+mW)?\z/i.match(line))
              [ [ :tx_power, match[2] ], [ :rx_power, match[3] ] ].each do |metric, raw_value|
                milliwatts = raw_value.match?(/\A\d+(?:\.\d+)?\z/) ? Float(raw_value) : nil
                if milliwatts && !milliwatts.finite?
                  issues << { code: :invalid_optics_measurement, interface: match[1], metric: metric }
                  milliwatts = nil
                end
                value = milliwatts && milliwatts.positive? ? 10 * Math.log10(milliwatts) : nil
                issues << { code: :zero_optical_power_unresolved, interface: match[1], metric: metric } if milliwatts == 0
                rows << { interface: match[1].downcase, lane: nil, metric: metric, value: value, unit: :dbm,
                  low_alarm: nil, low_warning: nil, high_warning: nil, high_alarm: nil, alarm: :unknown,
                  present: true, dom_supported: milliwatts.nil? ? nil : true }
              end
            elsif !line.empty? && !line.match?(/\A-+\z/)
              issues << { code: :unrecognized_optics_line }
            end
          end
          build_result(rows, complete: complete, recognized: header && rows.any?, issues: issues, identity: %i[interface lane metric])
        end
      end
    end
  end
end
