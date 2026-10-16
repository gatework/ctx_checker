# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module H3c
    module Parsers
      # 诊断表保留各光通道及模块自身阈值。
      class DisplayTransceiverDiagnosis < CtxChecker::Parsers::Base
        NUMBER = /(?:-?\d+(?:\.\d+)?|N\/A|--)/i
        ABSENT = /\A(?:The )?(?:transceiver is absent|no transceiver|transceiver is not present)\.?\z/i
        DOM_UNSUPPORTED = /\A(?:(?:The )?transceiver does not support (?:digital diagnosis|diagnostic(?: information)?|this function)|(?:The )?diagnostic information is not supported)\.?\z/i
        OPERATION_UNSUPPORTED = /\AThe operation is not supported\.\z/i

        private

        # 解析 display transceiver diagnosis，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues = [], []
          text.split(/(?=^\S+ transceiver diagnostic information:)/i).each do |block|
            next if block.strip.empty?
            match = /\A(\S+) transceiver diagnostic information:/i.match(block)
            unless match
              issues << { code: :unrecognized_optics_block }
              next
            end
            name = CtxChecker::Parsers::InterfaceNames.normalize(match[1], platform: :h3c)
            lines = block.lines.drop(1).map(&:strip).reject(&:empty?)
            if (state = availability(lines, name))
              rows.concat(measurements(name, nil, nil, nil, **state))
              next
            end
            samples, limits, section, mode = [], {}, nil, nil
            lines.each do |line|
              case line
              when /\ACurrent diagnostic parameters:/i then section, mode = :current, nil
              when /\AAlarm thresholds:/i then section, mode = :alarm, nil
              when /\AWarning thresholds:/i then section, mode = :warning, nil
              when /RX power\(dBm\)\s+TX power\(dBm\)\z/i
                mode = line.start_with?("[channel]") ? :lanes : :single
              else
                if section == :current && mode == :single && (sample = /\A#{NUMBER}\s+#{NUMBER}\s+#{NUMBER}\s+(#{NUMBER})\s+(#{NUMBER})\z/i.match(line))
                  samples << [ nil, number(sample[1], interface: name), number(sample[2], interface: name) ]
                elsif section == :current && mode == :lanes && (sample = /\A(\d+)\s+#{NUMBER}\s+(#{NUMBER})\s+(#{NUMBER})\z/i.match(line))
                  samples << [ sample[1].to_i, number(sample[2], interface: name), number(sample[3], interface: name) ]
                elsif %i[alarm warning].include?(section) && mode && (limit = /\A(High|Low)\s+#{NUMBER}\s+#{NUMBER}\s+#{NUMBER}\s+(#{NUMBER})\s+(#{NUMBER})\z/i.match(line))
                  key = "#{limit[1].downcase}_#{section}".to_sym
                  if limits.key?(key)
                    issues << { code: :duplicate_optics_threshold, interface: name }
                  else
                    limits[key] = [ number(limit[2], interface: name), number(limit[3], interface: name) ]
                  end
                elsif line.match?(/\A(?:High|Low)\b/) || (mode && line.match?(/\A[-\d]/))
                  issues << { code: :invalid_optics_measurement, interface: name }
                elsif !line.empty? && !line.match?(/\A-+\z/)
                  issues << { code: :unrecognized_optics_field, interface: name }
                end
              end
            end
            issues << { code: :optics_measurements_missing, interface: name } if samples.empty?
            samples.each do |lane, rx, tx|
              measurements(name, lane, rx, tx, present: true, dom_supported: true).each_with_index do |record, index|
                limits.each { |key, values| record[key] = values[index] }
                rows << record
              end
            end
          end
          build_result(rows, complete: complete, recognized: rows.any?, issues: issues, identity: %i[interface lane metric])
        end

        # 状态标记不能掩盖后续数据、重复状态或未知诊断内容。
        def availability(lines, name)
          absent = lines.any? { |line| ABSENT.match?(line) }
          unsupported = lines.any? { |line| DOM_UNSUPPORTED.match?(line) }
          operation_unsupported = lines.any? { |line| OPERATION_UNSUPPORTED.match?(line) }
          return unless absent || unsupported || operation_unsupported

          if lines.size != 1
            @issues << { code: :ambiguous_optics_availability, interface: name }
            return { present: nil, dom_supported: nil }
          end
          { present: operation_unsupported ? nil : !absent, dom_supported: absent ? nil : false }
        end

        # 解析数值测量，不将未知文本转换为零。
        def number(value, interface:)
          return unless value.match?(/\A-?\d+(?:\.\d+)?\z/)

          number = Float(value)
          return number if number.finite?

          @issues << { code: :invalid_optics_measurement, interface: interface }
          nil
        end

        # 提取支持的传感器值，保留测量不可用的状态。
        def measurements(name, lane, rx, tx, present:, dom_supported:)
          [ [ :rx_power, rx ], [ :tx_power, tx ] ].map do |metric, value|
            { interface: name, lane: lane, metric: metric, value: value, unit: :dbm,
              low_alarm: nil, low_warning: nil, high_warning: nil, high_alarm: nil, alarm: :unknown,
              present: present, dom_supported: dom_supported }
          end
        end
      end
    end
  end
end
