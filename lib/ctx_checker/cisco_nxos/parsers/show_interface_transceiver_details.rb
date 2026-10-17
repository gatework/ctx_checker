# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module CiscoNxos
    module Parsers
      # NX-OS DOM 按接口及可选光通道组织测量值。
      class ShowInterfaceTransceiverDetails < CtxChecker::Parsers::Base
        POWER = /([+-]?\d+(?:\.\d+)?\s+dBm|(?:N\/A|NA|--)(?:\s+dBm)?)/i
        MARKERS = { "++" => :high_alarm, "+" => :high_warning, "--" => :low_alarm, "-" => :low_warning }.freeze

        private

        # 保留 DOM 不可用和模块缺失状态，不虚构光功率。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues, devices = [], diagnostics, []
          current, lane, header, lane_valid = nil, nil, false, true
          text.each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty? || line.match?(/\A[-= ]+\z/)

            if line.match?(/\A(?:Eth(?:ernet)?|mgmt)\d[\d\/.]*\z/i)
              current = { interface: CtxChecker::Parsers::InterfaceNames.normalize(line, platform: :cisco_nxos),
                applicable: nil, present: nil, dom_supported: nil, lanes: [], presence_states: [], dom_unsupported: false }
              devices << current
              lane, header, lane_valid = nil, false, true
            elsif current && (match = /\Atransceiver is (not )?present\z/i.match(line))
              current[:present] = match[1].nil?
              current[:presence_states] << current[:present]
            elsif current && line.match?(/\Atransceiver is not applicable\z/i)
              current[:applicable] = false
              current[:dom_supported] = false
            elsif current && line.match?(/\ADOM is not supported\z/i)
              current[:dom_supported] = false
              current[:dom_unsupported] = true
            elsif current && (match = /\ALane Number\s*:\s*(\d+)(?:\s+Network Lane)?\z/i.match(line))
              lane = Integer(match[1], 10)
              current[:lanes] << lane
              header, lane_valid = false, true
            elsif current && line.match?(/\ALane Number\b/i)
              lane, header, lane_valid = nil, false, false
              issues << { code: :invalid_optical_lane, line: number, interface: current[:interface] }
            elsif current && line.match?(/\AMeasurement\s+High\s+Low\s+High\s+Low\z/i)
              header = true
            elsif current && (match = /\A(Tx Power|Rx Power)\s+(.+)\z/i.match(line))
              next unless lane_valid

              row = measurement(match[1], match[2], current, lane)
              if row
                rows << row
                current[:dom_supported] = true
                issues << { code: :missing_optical_header, line: number } unless header
              else
                issues << { code: :unparsed_optical_measurement, line: number }
              end
            elsif current && auxiliary?(line)
              next
            else
              issues << { code: :unparsed_row, line: number }
            end
          end
          by_interface = rows.group_by { |row| row[:interface] }
          devices.each { |device| complete_measurements(rows, device, issues, by_interface) }
          build_result(rows, complete: complete, recognized: devices.any?, issues: issues, identity: %i[interface lane metric])
        end

        # 解析支持的传感器测量值及回显单位。
        def measurement(label, values, device, lane)
          match = /\A#{POWER}\s*(\+\+|\+|--|-)?\s+#{POWER}\s+#{POWER}\s+#{POWER}\s+#{POWER}\z/i.match(values)
          return unless match

          current, marker, high_alarm, low_alarm, high_warning, low_warning = match.captures
          value = decimal(current)
          base_record(device, lane, label.downcase.start_with?("tx") ? :tx_power : :rx_power).merge(
            value: value, high_alarm: decimal(high_alarm), low_alarm: decimal(low_alarm),
            high_warning: decimal(high_warning), low_warning: decimal(low_warning),
            alarm: marker ? MARKERS.fetch(marker) : (value.nil? ? :unknown : :normal), dom_supported: true)
        end

        # 即使配对指标解析成功，缺失指标仍须明确保留。
        def complete_measurements(rows, device, issues, by_interface)
          device_rows = by_interface[device[:interface]] ||= []
          measurements = device_rows.to_h { |row| [ row.values_at(:lane, :metric), true ] }
          if device[:applicable] == false && (!device[:presence_states].empty? || device[:lanes].any? || device_rows.any?)
            issues << { code: :contradictory_optical_applicability, interface: device[:interface] }
            device[:applicable] = nil
            device_rows.each { |row| row[:applicable] = nil }
          end
          if device[:presence_states].uniq.size > 1
            issues << { code: :contradictory_transceiver_presence, interface: device[:interface] }
          end
          if device[:dom_unsupported] && device_rows.any? { |row| !row[:value].nil? }
            issues << { code: :contradictory_dom_support, interface: device[:interface] }
          end
          lanes = device[:lanes].empty? ? [ nil ] : device[:lanes].uniq
          lanes.each do |lane|
            %i[tx_power rx_power].each do |metric|
              next if measurements.key?([ lane, metric ])

              record = base_record(device, lane, metric)
              rows << record
              device_rows << record
              measurements[[ lane, metric ]] = true
              unless device[:present] == false || device[:dom_supported] == false
                issues << { code: :optical_measurement_missing, interface: device[:interface], lane: lane, metric: metric }
              end
            end
          end
          if device[:present].nil? && device[:applicable] != false
            issues << { code: :transceiver_presence_unknown, interface: device[:interface] }
          end
          if device[:present] == false && device_rows.any? { |row| !row[:value].nil? }
            issues << { code: :contradictory_transceiver_presence, interface: device[:interface] }
          end
        end

        # 构建同一资源各测量值共用的身份字段。
        def base_record(device, lane, metric)
          { interface: device[:interface], lane: lane, metric: metric, value: nil, unit: :dbm,
            low_alarm: nil, low_warning: nil, high_warning: nil, high_alarm: nil, alarm: :unknown,
            applicable: device[:applicable], present: device[:present], dom_supported: device[:dom_supported] }
        end

        # 解析有限小数，不将占位符转换为零。
        def decimal(value)
          value = value.sub(/\s+dBm\z/i, "")
          return unless value.match?(/\A[+-]?\d+(?:\.\d+)?\z/)

          parsed = Float(value)
          return parsed if parsed.finite?

          @issues << { code: :invalid_optical_value }
          nil
        end

        # 识别说明性回显，不将其作为数据记录。
        def auxiliary?(line)
          line.match?(/\A(?:(?:type|name|part number|revision|serial number|nominal bitrate|cisco [\w ]+|connector type|encoding|host lane count|power class) is\b|Link length supported |(?:SFP|QSFP) Detail Diagnostics Information |Current\s+Alarms\s+Warnings\z|(?:Temperature|Voltage|Current)\s+(?:[+-]?\d|N\/A)|Transmit Fault Count\s*=\s*\d+\z|Note:|\+\+ :|\*\* :|\+ :|\- :|\-\- :)/i)
        end
      end
    end
  end
end
