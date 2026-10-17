# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module Hillstone
    module Parsers
      # StoneOS 仅列出在线接口的累计丢弃量，不提供 CRC 或错误总数。
      class ShowInterfaceCounter < CtxChecker::Parsers::Base
        HEADER = /\Ainterface\s+in frames\s+in octets\s+out frames\s+out octets\s+in discard\s+out discard\z/i
        ROW = /\A([a-z][\w\/.-]*)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\z/i

        private

        # 解释计数器前先校验列顺序；缺少采样时保留 nil。
        def parse_output(text, complete:)
          rows, issues, header, count = [], diagnostics, false, 0
          clean(text).each_line do |raw|
            line = raw.strip
            next if line.empty? || /\A[-=]+\z/.match?(line)

            if HEADER.match?(line)
              issues << { code: :duplicate_counter_header } if header
              header = true
            elsif /\Ainterface\b/i.match?(line)
              header = false
              issues << { code: :unrecognized_counter_header }
            elsif header && (match = ROW.match(line))
              count += 1
              name = CtxChecker::Parsers::InterfaceNames.normalize(match[1], platform: :hillstone)
              if CtxChecker::Parsers::InterfaceNames.kind(name) == :unknown
                issues << { code: :unknown_counter_interface, interface: name }
              end
              unless match.captures[1, 4].all? { |value| /\A\d+\z/.match?(value) }
                issues << { code: :invalid_traffic_counter, interface: name }
              end
              %i[in_discards out_discards].zip(match.captures.last(2)).each do |metric, value|
                issues << { code: :invalid_counter_value, interface: name, metric: metric } unless /\A\d+\z/.match?(value)
                rows << { interface: name, metric: metric, value: /\A\d+\z/.match?(value) ? Integer(value, 10) : nil,
                  discontinuity: nil }
              end
            else
              issues << { code: :unrecognized_counter_line }
            end
          end
          issues << { code: :empty_counter_table } if header && count.zero?
          build_result(rows, complete: complete, recognized: header || rows.any?, issues: issues,
            identity: %i[interface metric])
        end
      end
    end
  end
end
