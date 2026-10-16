# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"
require "ctx_parser/values"

module CtxChecker
  module CiscoIos
    module Parsers
      # OSPF 身份包含进程、VRF、接口和路由器 ID；未知作用域保留为 nil。
      class ShowIpOspfNeighbor < CtxChecker::Parsers::Base
        PLATFORM = :cisco_ios
        STATES = { "FULL" => :full, "2WAY" => :two_way, "2-WAY" => :two_way, "DOWN" => :down,
          "ATTEMPT" => :attempt, "INIT" => :init, "EXSTART" => :exstart, "EXCHANGE" => :exchange,
          "LOADING" => :loading }.freeze

        private

        # 解析 show ip ospf neighbor，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues = [], []
          scope = { vrf: "default", process_id: nil, area: nil }
          sections = []
          section = { header: false, empty: false, count: 0, totals: [], declared: false, scope: scope }
          sections << section
          text.each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty? || line.match?(/\A[-= ]+\z/)

            if line.match?(/\ANeighbor ID\s+Pri\s+State\s+(?:Dead Time|Up Time)\s+Address\s+Interface\z/i)
              section[:header] = true
            elsif (match = /\AOSPF\s+Process\s+ID\s+(\S+)\s+VRF\s+(\S+)\z/i.match(line))
              scope = { vrf: match[2], process_id: match[1], area: nil }
              section = { header: false, empty: false, count: 0, totals: [], declared: true, scope: scope }
              sections << section
            elsif (match = /\A(?:Process ID|OSPF Process(?!\s+ID\b))\s*:?\s*(\S+)(?:,?\s+VRF\s+(\S+))?\z/i.match(line))
              scope = { vrf: match[2] || "default", process_id: match[1], area: nil }
              section = { header: false, empty: false, count: 0, totals: [], declared: true, scope: scope }
              sections << section
            elsif line.match?(/\A(?:OSPF\s+Process\b|Process ID\b)/i)
              issues << { code: :invalid_protocol_scope, line: number }
              scope = { vrf: nil, process_id: nil, area: nil }
              section = { header: false, empty: false, count: 0, totals: [], declared: true, scope: scope }
              sections << section
            elsif (match = /\ATotal number of neighbors:\s*(\d+)\z/i.match(line))
              section[:totals] << Integer(match[1], 10)
            elsif line.match?(/\A(?:No (?:OSPF )?neighbors(?: found)?\.?|0 (?:OSPF )?neighbors)\z/i)
              section[:empty] = true
            elsif (row = parse_neighbor(line, scope))
              rows << row
              section[:count] += 1
            else
              issues << { code: :unparsed_row, line: number }
            end
          end
          sections.each do |entry|
            entry[:totals].each do |total|
              issues << { code: :count_mismatch, expected: total, observed: entry[:count] } unless total == entry[:count]
            end
            issues << { code: :contradictory_empty } if entry[:empty] && entry[:count].positive?
            if entry[:count].positive? && !entry[:header]
              issues << { code: :missing_neighbor_header }
            elsif (entry[:header] || entry[:declared]) && entry[:count].zero? && !entry[:empty] && !entry[:totals].include?(0)
              issues << { code: :neighbor_count_unavailable }
            end
          end
          recognized = sections.any? { |entry| entry[:empty] || entry[:totals].include?(0) || entry[:header] && entry[:count].positive? }
          scopes = sections.filter_map do |entry|
            value = entry[:scope].slice(:vrf, :process_id)
            value if value.values.none?(&:nil?) && (entry[:empty] || entry[:totals].include?(0) || entry[:header] && entry[:count].positive?)
          end
          build_result(rows, complete: complete, recognized: recognized, issues: issues,
            identity: %i[vrf process_id interface router_id], covered_scopes: scopes)
        end

        # 解析协议邻居行的状态及稳定身份。
        def parse_neighbor(line, scope)
          match = /\A(\S+)\s+(\d+)\s+(FULL|2WAY|2-WAY|DOWN|ATTEMPT|INIT|EXSTART|EXCHANGE|LOADING)\/(?:\s*)(DR|BDR|DROTHER|-)\s+\S+\s+(\S+)\s+(\S+)\z/i.match(line)
          return unless match && (0..255).cover?(Integer(match[2], 10)) &&
            ipv4_address?(match[1]) && ipv4_address?(match[5])

          scope.merge(interface: CtxChecker::Parsers::InterfaceNames.normalize(match[6], platform: self.class::PLATFORM),
            router_id: CtxParser::Values.host(match[1]), neighbor_address: CtxParser::Values.host(match[5]),
            state: STATES.fetch(match[3].upcase), network_type: :unknown, local_role: :unknown,
            neighbor_role: match[4] == "-" ? :unknown : match[4].downcase.to_sym)
        end

        # OSPFv2 路由器 ID 与接口地址必须是 IPv4 主机地址。
        def ipv4_address?(text)
          text.match?(/\A\d+(?:\.\d+){3}\z/) && CtxParser::Values.valid_host?(text)
        end
      end
    end
  end
end
