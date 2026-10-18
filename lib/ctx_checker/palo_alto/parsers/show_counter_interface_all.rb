# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module PaloAlto
    module Parsers
      # CPU 接收错误属于 L2 至 L4 错误，不能替代 MAC CRC 错误。
      class ShowCounterInterfaceAll < CtxChecker::Parsers::Base
        METRICS = {
          "receive errors" => :in_errors, "transmit errors" => :out_errors,
          "receive discarded" => :in_discards, "receive packets dropped" => :in_discards,
          "transmit packets dropped" => :out_discards
        }.freeze
        DETAIL = /\A(?:bytes (?:received|transmitted)|packets (?:received|transmitted|dropped(?: by flow state check)?|routed to different zone)|receive incoming errors|forwarding errors|no route|arp not found|neighbor (?:not found|info pending)|mac not found|land attacks|ping-of-death attacks|teardrop attacks|[im]ac spoof attacks|ip spoof attacks|ICMP fragment|layer2 (?:encapsulated|decapsulated) packets|multicast packets received|(?:tcp|udp|sctp|other) cps)\s+\d+\z/i

        private

        # 解析 show counter interface all，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues, interfaces = [], diagnostics, {}
          text.split(/(?=^\s*Interface:)/i).each do |block|
            next if block.strip.empty?
            match = /\A\s*Interface:\s*([^\n]+)\n/i.match(block)
            unless match
              lines = block.lines("\n").map(&:strip).reject { |line| line.empty? || line.match?(/\A-+\z/) }
              issues << { code: :unrecognized_counter_block } unless lines == [ "Hardware interface counters:" ]
              next
            end
            name = match[1].strip.casecmp?("Management Interface") ? "management" : match[1].strip.downcase
            interfaces[name] = true
            kind = CtxChecker::Parsers::InterfaceNames.kind(name)
            wanted = kind == :physical ? :hardware : :logical
            section, values = nil, []
            block.lines("\n").drop(1).each do |raw|
              line = raw.strip
              if (heading = /\A(Hardware|Logical) interface counters(?: read from CPU)?:\z/i.match(line))
                section = heading[1].downcase.to_sym
              elsif line.match?(/\A(?:Detailed )?Physical port counters read from MAC:\z/i)
                section = :mac
              elsif line.empty? || line.match?(/\A-+\z/)
                next
              elsif section == wanted && (metric = /\A(.+?)\s+(\d+)\z/.match(line)) && METRICS.key?(metric[1].downcase)
                values << { interface: name, metric: METRICS.fetch(metric[1].downcase), value: Integer(metric[2], 10), discontinuity: nil,
                  unit: :packets, scope: section == :hardware ? :cpu : :logical }
              elsif section == wanted && !DETAIL.match?(line)
                issues << { code: :unrecognized_counter_field, interface: name }
              elsif section.nil?
                issues << { code: :counter_section_missing, interface: name }
              end
            end
            rows.concat(values)
          end
          # 同一接口可能同时出现在硬件与逻辑清单中，须先确定其标准层级，
          # 再补齐缺失指标，不能按每个展示块重复生成。
          by_interface = rows.group_by { |row| row[:interface] }
          interfaces.each_key do |name|
            missing = %i[in_errors out_errors in_discards out_discards crc_errors] - by_interface.fetch(name, []).map { |row| row[:metric] }
            missing.each { |metric| rows << { interface: name, metric: metric, value: nil, discontinuity: nil } }
            issues << { code: :missing_counter_metrics, interface: name, metrics: missing } if missing.any?
          end
          build_result(rows, complete: complete, recognized: interfaces.any?, issues: issues, identity: %i[interface metric])
        end
      end
    end
  end
end
