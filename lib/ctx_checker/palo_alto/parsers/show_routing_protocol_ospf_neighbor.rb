# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module PaloAlto
    module Parsers
      # 旧版 PAN-OS 邻居回显不标明本地接口或进程。
      class ShowRoutingProtocolOspfNeighbor < CtxChecker::Parsers::Base
        STATES = { "full" => :full, "down" => :down, "init" => :init, "attempt" => :attempt,
          "2-way" => :two_way, "two way" => :two_way, "exchange start" => :exstart, "exstart" => :exstart,
          "exchange" => :exchange, "loading" => :loading }.freeze
        FIELDS = /\A(?:virtual router:|neighbor address:|local address binding:|type:|status:|neighbor router ID:|area id:|neighbor priority:|lifetime remain:|messages pending:|LSA request pending:|options:|hello suppressed:|restart helper status:|restart helper time remaining:|restart helper exit reason:|=+\z)/i

        private

        # 解析 show routing protocol ospf neighbor，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues = [], diagnostics
          text.split(/(?=^\s*virtual router:)/i).each do |block|
            unless block.match?(/\A\s*virtual router:/i)
              # 文档规定的图例位于首个邻居前，任意前导文本不构成证据。
              lines = block.lines.map(&:strip).reject(&:empty?)
              unless lines.all? { |line| line.match?(/\A(?:=+|Options: 0x80:reserved,.*|N\/P:NSSA option,.*)\z/i) }
                issues << { code: :unrecognized_ospf_block }
              end
              next
            end
            issues << { code: :unrecognized_ospf_field } if block.lines.any? { |line| !line.strip.empty? && !FIELDS.match?(line.strip) }
            if [ "neighbor address", "neighbor router ID", "status" ].any? { |field| block.scan(/^\s*#{Regexp.escape(field)}:/i).size > 1 }
              issues << { code: :duplicate_ospf_field }
              next
            end
            neighbor = block[/^\s*neighbor address:\s*(\S+)/i, 1]
            router_id = block[/^\s*neighbor router ID:\s*(\S+)/i, 1]
            unless CtxParser::Values.ip_address?(neighbor) && CtxParser::Values.ip_address?(router_id)
              issues << { code: :ospf_neighbor_identity_missing }
              next
            end
            neighbor = CtxParser::Values.ip_address(neighbor)
            router_id = CtxParser::Values.ip_address(router_id)
            state = STATES.fetch(block[/^\s*status:\s*(.+)$/i, 1]&.strip&.downcase, :unknown)
            issues << { code: :ospf_state_unknown } if state == :unknown
            rows << { vrf: block[/^\s*virtual router:\s*(\S+)/i, 1], process_id: nil,
              area: block[/^\s*area id:\s*(\S+)/i, 1], interface: nil, router_id: router_id, neighbor_address: neighbor,
              state: state, network_type: :unknown, local_role: :unknown, neighbor_role: :unknown }
          end
          build_result(rows, complete: complete, recognized: rows.any?, issues: issues, identity: %i[vrf process_id interface router_id neighbor_address])
        end
      end
    end
  end
end
