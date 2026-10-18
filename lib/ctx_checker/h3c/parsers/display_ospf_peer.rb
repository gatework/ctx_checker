# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module H3c
    module Parsers
      # 邻居表作用域由进程和区域标题确定。
      class DisplayOspfPeer < CtxChecker::Parsers::Base
        private

        # 解析 display ospf peer，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          if /\AOSPF is not configured\.\z/i.match?(text.strip)
            return build_result([], complete: complete, recognized: true, issues: [ { code: :protocol_not_configured } ])
          end
          rows, issues, process, area, header = [], diagnostics, nil, nil, false
          text.each_line("\n") do |raw|
            line = raw.strip
            if (match = /\AOSPF Process (\d+) with Router ID ([\d.]+)\z/i.match(line))
              process, area = match[1], nil
            elsif (match = /\AArea:\s*([\d.]+)\z/i.match(line))
              area = match[1]
            elsif /\ARouter ID\s+Address\s+Pri\s+Dead-Time\s+State\s+Interface\z/i.match?(line)
              header = true
            elsif (match = /\A([\d.]+)\s+([\d.]+)\s+\d+\s+\S+\s+(Down|Init|Attempt|2-Way|Exstart|Exchange|Loading|Full)(?:\/[ \t]*(DR|BDR|DROther|-))?\s+(\S+)\z/i.match(line))
              if CtxParser::Values.ip_address?(match[1]) && CtxParser::Values.ip_address?(match[2])
                issues << { code: :ospf_scope_missing } unless process && area
                rows << { vrf: nil, process_id: process, area: area,
                  interface: CtxChecker::Parsers::InterfaceNames.normalize(match[5], platform: :h3c), router_id: match[1], neighbor_address: match[2],
                  state: match[3].downcase == "2-way" ? :two_way : match[3].downcase.to_sym,
                  network_type: :unknown, local_role: :unknown, neighbor_role: match[4] && match[4] != "-" ? match[4].downcase.to_sym : :unknown }
              else
                issues << { code: :invalid_ospf_peer }
              end
            elsif !line.empty? && line != "Neighbor Brief Information"
              issues << { code: :unrecognized_ospf_line }
            end
          end
          build_result(rows, complete: complete, recognized: header && rows.any?, issues: issues, identity: %i[vrf process_id interface router_id])
        end
      end
    end
  end
end
