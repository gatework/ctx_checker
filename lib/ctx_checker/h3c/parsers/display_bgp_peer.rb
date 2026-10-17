# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module H3c
    module Parsers
      # 公网 IPv4 单播查询具有明确的地址族作用域。
      class DisplayBgpPeer < CtxChecker::Parsers::Base
        STATES = %w[idle connect active opensent openconfirm established idle(admin)].freeze

        private

        # 解析 display bgp peer，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues, total, header = [], diagnostics, nil, false
          text.each_line do |raw|
            line = raw.strip
            if (match = /\ATotal number of peers:\s*(\d+)\z/i.match(line))
              issues << { code: :duplicate_peer_count } unless total.nil?
              total = Integer(match[1], 10)
            elsif /\APeer\s+AS\s+MsgRcvd\s+MsgSent\s+OutQ\s+PrefRcv\s+Up\/Down\s+State\z/i.match?(line)
              header = true
            elsif (match = /\A\*?\s*([\d.]+)\s+(\d+)\s+\d+\s+\d+\s+\d+\s+(\d+)\s+\S+\s+(.+)\z/.match(line))
              state = match[4].downcase.delete(" ")
              if CtxParser::Values.ip_address?(match[1]) && STATES.include?(state) && (1..4_294_967_295).cover?(match[2].to_i)
                rows << { vrf: "default", afi_safi: "ipv4_unicast", peer: match[1], state: state == "idle(admin)" ? :shutdown : state.to_sym,
                  received_prefixes: match[3].to_i, remote_as: match[2].to_i }
              else
                issues << { code: :invalid_bgp_peer }
              end
            elsif !line.empty? && !line.match?(/\A(?:BGP local router ID:|Local AS number:|\* - Dynamically created peer)/i)
              issues << { code: :unrecognized_bgp_line }
            end
          end
          issues << { code: :count_mismatch, expected: total, observed: rows.size } if total && total != rows.size
          build_result(rows, complete: complete, recognized: header && (rows.any? || total == 0), issues: issues,
            identity: %i[vrf afi_safi peer], covered_scopes: [ { vrf: "default", afi_safi: "ipv4_unicast" } ])
        end
      end
    end
  end
end
