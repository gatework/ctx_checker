# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module CiscoIos
    module Parsers
      # IOS DOM 按指标分表展示端口，其阈值顺序不同于 NX-OS。
      class ShowInterfacesTransceiverDetail < CtxChecker::Parsers::Base
        NUMBER = /(?:[+-]?\d+(?:\.\d+)?|N\/A|NA|--)/i
        MARKERS = { "++" => :high_alarm, "+" => :high_warning, "--" => :low_alarm, "-" => :low_warning }.freeze

        private

        # 解析 show interfaces transceiver detail，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues, ports = [], [], []
          metric, header, lane_column = nil, false, false
          text.each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty? || line.match?(/\A[-= ]+\z/)

            if line.match?(/\bTransmit Power\b/i)
              metric, header = :tx_power, false
            elsif line.match?(/\bReceive Power\b/i)
              metric, header = :rx_power, false
            elsif line.match?(/\A(?:Temperature|Voltage|Current)\s+Threshold/i)
              metric, header = :other, false
            elsif line.match?(/\APort\s+(?:Lane\s+)?\(/i)
              header = true
              lane_column = line.match?(/\APort\s+Lane\s/i)
            elsif interface_row?(line)
              name = CtxChecker::Parsers::InterfaceNames.normalize(line.split.first, platform: :cisco_ios)
              ports << name
              if metric && header
                next if metric == :other

                row = measurement(line, metric, lane_column)
                row ? rows << row : issues << { code: :unparsed_optical_measurement, line: number }
              else
                issues << { code: :missing_optical_header, line: number }
              end
            elsif auxiliary?(line)
              next
            else
              issues << { code: :unparsed_row, line: number }
            end
          end
          identities = rows.map { |row| row.values_at(:interface, :lane) }
          identities.concat((ports.uniq - rows.map { |row| row[:interface] }).map { |name| [ name, nil ] })
          identities.uniq.each do |name, lane|
            %i[tx_power rx_power].each do |expected|
              next if rows.any? { |row| row.values_at(:interface, :lane, :metric) == [ name, lane, expected ] }

              issues << { code: :optical_measurement_missing, interface: name, lane: lane, metric: expected }
            end
          end
          build_result(rows, complete: complete, recognized: rows.any?, issues: issues, identity: %i[interface lane metric])
        end

        # 解析支持的传感器测量值及回显单位。
        def measurement(line, metric, lane_column)
          # 括号内 A2D 读数属于独立校准证据，不作为阈值。
          normalized = line.gsub(/\(\s*#{NUMBER}\s*\)/i, "")
          columns = normalized.split
          name = CtxChecker::Parsers::InterfaceNames.normalize(columns.shift, platform: :cisco_ios)
          lane = lane_column ? columns.shift : nil
          lane = nil if lane && /\AN\/?A\z/i.match?(lane)
          return if lane && !lane.match?(/\A\d+\z/)

          current = columns.shift
          marker = columns.shift if MARKERS.key?(columns.first)
          return unless current&.match?(/\A#{NUMBER}\z/) && columns.size == 4 && columns.all? { |value| value.match?(/\A#{NUMBER}\z/) }

          high_alarm, high_warning, low_warning, low_alarm = columns.map { |value| decimal(value) }
          { interface: name, lane: lane && Integer(lane, 10), metric: metric, value: decimal(current), unit: :dbm,
            low_alarm: low_alarm, low_warning: low_warning, high_warning: high_warning, high_alarm: high_alarm,
            alarm: marker ? MARKERS.fetch(marker) : :normal, present: true, dom_supported: true }
        end

        # 区分接口数据行与表格标题。
        def interface_row?(line)
          name = CtxChecker::Parsers::InterfaceNames.normalize(line.split.first, platform: :cisco_ios)
          CtxChecker::Parsers::InterfaceNames.kind(name) == :physical
        end

        # 解析有限小数，不将占位符转换为零。
        def decimal(value)
          return unless value.match?(/\A[+-]?\d+(?:\.\d+)?\z/)

          parsed = Float(value)
          return parsed if parsed.finite?

          @issues << { code: :invalid_optical_value }
          nil
        end

        # 识别说明性回显，不将其作为数据记录。
        def auxiliary?(line)
          line.match?(/\A(?:mA: |\+\+\s*:|A2D readouts |The threshold values |(?:Optical\s+)?High Alarm\s+High Warn\s+Low Warn\s+Low Alarm\z|Optical\z|ITU Channel |Transceiver is |Transceiver monitoring is |Wavelength |(?:Temperature|Voltage|Current)\s+Threshold)/i)
        end
      end
    end
  end
end
