# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module PaloAlto
    module Parsers
      # 同一对等体可能报告多个地址族。
      class ShowRoutingProtocolBgpPeer < CtxChecker::Parsers::Base
        STATES = %w[established idle active connect opensent openconfirm shutdown].freeze
        FIELDS = /\A(?:Peer:|virtual router:|Peer router id:|Remote AS:|Peer group:|Peer status:|Password set:|Passive:|Multi-hop TTL:|Remote Address:|Local Address:|\(R\) reflector client:|same confederation:|send aggr confed as-path:|peering type:|Connect-Retry interval:|Open Delay:|Idle Hold:|Prefix limit:|Holdtime:|Keep-Alive interval:|Update messages:|Total messages:|Last update age:|Last error:|Flap counts:|\(R\) ORF entries:|Nexthop set to self:|use 3rd party as next-hop:|override nexthop to peer_address:|remove private AS number:|Capability:|Prefix counter for:|Incoming Prefix:|Outgoing Prefix:|Advertised Prefix:|[-=]+\z)/i

        private

        # 解析 show routing protocol bgp peer，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues = [], diagnostics
          text.split(/(?=^\s*Peer:\s)/i).each do |block|
            next if block.strip.empty? || block.strip.match?(/\A=+\z/)
            unless block.match?(/\A\s*Peer:\s/i)
              issues << { code: :unrecognized_bgp_block }
              next
            end
            if block.lines("\n").any? { |line| !line.strip.empty? && !FIELDS.match?(line.strip) }
              issues << { code: :unrecognized_bgp_field }
            end
            if [ "Remote Address", "Peer status", "Remote AS", "virtual router" ].any? { |field| block.scan(/^\s*#{Regexp.escape(field)}:/i).size > 1 }
              issues << { code: :duplicate_bgp_field }
              next
            end
            address = block[/^\s*Remote Address:\s*(\S+)/i, 1]
            peer = address&.sub(/\A\[([^\]]+)\]:\d+\z/, '\1')
            peer = peer.sub(/:\d+\z/, "") if peer&.match?(/\A\d+(?:\.\d+){3}:\d+\z/)
            unless CtxParser::Values.ip_address?(peer)
              issues << { code: :bgp_peer_address_missing }
              next
            end
            peer = CtxParser::Values.ip_address(peer)
            state = block[/^\s*Peer status:\s*([^,\n]+)/i, 1]&.strip&.downcase
            state = STATES.include?(state) ? state.to_sym : :unknown
            remote_as = block[/^\s*Remote AS:\s*(\d+)\s*$/i, 1]&.to_i
            if remote_as && !(1..4_294_967_295).cover?(remote_as)
              issues << { code: :invalid_bgp_asn }
              remote_as = nil
            end
            issues << { code: :bgp_peer_fields_missing } if state == :unknown || remote_as.nil?
            base = { vrf: block[/^\s*virtual router:\s*(\S+)/i, 1], peer_address: peer, state: state, remote_as: remote_as }
            families = block.split(/(?=^\s*Prefix counter for:)/i).drop(1)
            if families.empty?
              rows << base.merge(afi_safi: nil, received_prefixes: nil)
            else
              families.each do |family|
                scope = /^[ \t]*Prefix counter for:[ \t]*bgpAfiIpv([46])[ \t]*\/[ \t]*(unicast|multicast)[ \t]*$/i.match(family)
                prefixes = family[/^\s*Incoming Prefix:\s*Accepted \d+, Rejected \d+, Policy Rej \d+, Total (\d+)\s*$/i, 1]
                issues << { code: :bgp_address_family_unknown } unless scope
                rows << base.merge(afi_safi: scope ? "ipv#{scope[1]}_#{scope[2].downcase}" : nil, received_prefixes: prefixes&.to_i)
              end
            end
          end
          build_result(rows, complete: complete, recognized: rows.any?, issues: issues, identity: %i[vrf afi_safi peer_address])
        end
      end
    end
  end
end
