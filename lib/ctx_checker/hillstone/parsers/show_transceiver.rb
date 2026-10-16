# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module Hillstone
    module Parsers
      # 光模块读数保留模块自身的正常、警告或告警范围。
      class ShowTransceiver < CtxChecker::Parsers::Base
        NUMBER = /[+-]?\d+(?:\.\d+)?/
        HEADER = /\ATransceiver status information is shown as below:\z/i
        BLOCK = /\A=+\s+((?:x?ethernet)\d+(?:\/\d+)+)\s+=+\z/i
        METADATA = /\A(?:SFP(?:\+\/XFP)? information:|Part Number:|Serial Number:|Transmission media:|Module temperature(?: (?:normal|warning|alarm) range)?:|Tx supply voltage(?: (?:normal|warning|alarm) range)?:|Tx bias current(?: (?:normal|warning|alarm) range)?:|Module Wavelength:|single module max transmit distance:|OM[123] max transmit distance:|OM4 or copper max transmit distance:)/i

        private

        # 逐模块隔离，避免未知块将测量值错误关联到前一模块。
        def parse_output(text, complete:)
          rows, issues, blocks, current, header = [], [], [], nil, false
          clean(text).each_line do |raw|
            line = raw.strip
            next if line.empty? || /\A=+\z/.match?(line)

            if HEADER.match?(line)
              issues << { code: :duplicate_optics_header } if header
              header = true
            elsif (match = BLOCK.match(line))
              current = { name: CtxChecker::Parsers::InterfaceNames.normalize(match[1], platform: :hillstone), lines: [] }
              blocks << current
            elsif line.start_with?("=")
              current = nil
              issues << { code: :unrecognized_optics_block }
            elsif current
              current[:lines] << line
            else
              issues << { code: :unrecognized_optics_line }
            end
          end
          blocks.each { |block| rows.concat(measurements(block, issues)) }
          issues << { code: :optics_header_missing } unless header
          issues << { code: :optics_measurements_missing } if blocks.empty?
          build_result(rows, complete: complete, recognized: header || blocks.any?, issues: issues,
            identity: %i[interface lane metric])
        end

        # 缺失或重复测量保持不可用，不替换为零。
        def measurements(block, issues)
          name = block[:name]
          values, limits, seen = {}, {}, Hash.new(0)
          block[:lines].each do |line|
            if (match = /\A(Tx|Rx) optical power:\s*(#{NUMBER}|N\/A|--)\s*dBm\z/i.match(line))
              metric = metric(match[1])
              set_value(values, metric, number(match[2]), seen, issues, name)
            elsif (match = /\A(Tx|Rx) optical power (normal|warning|alarm) range:\s*\[\s*(#{NUMBER})\s*[,，]\s*(#{NUMBER})\s*\]\z/i.match(line))
              metric = metric(match[1])
              level = match[2].casecmp?("alarm") ? :alarm : :warning
              low, high = number(match[3]), number(match[4])
              limits[metric] ||= {}
              %i[low high].zip([ low, high ]).each do |bound, value|
                key = "#{bound}_#{level}".to_sym
                set_value(limits[metric], key, value, seen, issues, name, identity: [ metric, key ])
              end
            elsif !METADATA.match?(line)
              issues << { code: :unrecognized_optics_field, interface: name }
            end
          end
          %i[tx_power rx_power].map do |metric|
            issues << { code: :optics_measurement_missing, interface: name, metric: metric } unless seen[metric].positive?
            { interface: name, lane: nil, metric: metric, value: values[metric], unit: :dbm,
              low_alarm: nil, high_alarm: nil, low_warning: nil, high_warning: nil,
              alarm: :unknown, present: true, dom_supported: values.key?(metric) ? true : nil }.merge(limits.fetch(metric, {}))
          end
        end

        # 即使数值相同，重复测量也使该指标失效。
        def set_value(values, key, value, seen, issues, name, identity: key)
          seen[identity] += 1
          if seen[identity] > 1
            values[key] = nil
            issues << { code: :duplicate_optics_value, interface: name }
          else
            values[key] = value
          end
        end

        # 标准测量名称独立于厂商标签。
        def metric(direction)
          direction.casecmp?("Tx") ? :tx_power : :rx_power
        end

        # 解析有限读数，明确保留 DOM 值不可用的状态。
        def number(value)
          return unless /\A#{NUMBER}\z/.match?(value)

          parsed = Float(value)
          parsed if parsed.finite?
        end
      end
    end
  end
end
