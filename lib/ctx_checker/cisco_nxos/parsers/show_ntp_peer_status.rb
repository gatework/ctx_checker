# frozen_string_literal: true

require_relative "../../parsers/base"
require "ipaddr"

module CtxChecker
  module CiscoNxos
    module Parsers
      # 所选 NTP 对等体用于证明同步，与报告 CFS 的 NX-OS show ntp status 区分。
      class ShowNtpPeerStatus < CtxChecker::Parsers::Base
        private

        # 解析 show ntp peer status，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          peers, issues, totals = [], diagnostics, []
          vrf_column = nil
          each_ntp_line(clean(text), issues) do |line, number|
            next if line.empty? || /\A-+\z/.match?(line)

            if (match = /\ATotal peers\s*:\s*(\d+)\z/i.match(line))
              totals << Integer(match[1], 10)
            elsif /\A(?:\*\s*-\s*selected for sync|\-\s*-\s*peer mode)/i.match?(line)
              next
            elsif (match = /\Aremote\s+local\s+st\s+poll\s+reach\s+delay(?:\s+(vrf))?\z/i.match(line))
              issues << { code: :duplicate_ntp_header, line: number } unless vrf_column.nil?
              vrf_column = !match[1].nil?
            else
              peer = peer_row(line, number, vrf_column, issues)
              peers << peer if peer
            end
          end
          issues << { code: :ntp_peer_count_mismatch } unless totals.one? && totals.first == peers.size
          issues << { code: :duplicate_identity } unless peers.map { |peer| peer.values_at(:peer_address, :vrf) }.uniq.size == peers.size
          selected = peers.select { |peer| peer[:selected] }
          issues << { code: :conflicting_ntp_selection } if selected.size > 1
          peer = selected.one? ? selected.first : nil
          issues << { code: :invalid_ntp_selection } if peer && (!peer[:reachable] || !peer[:stratum].between?(1, 14))
          issues << { code: :local_ntp_reference } if peer && peer[:peer_address] == "127.127.1.0"
          recognized = totals.any? || peers.any?
          synchronized = issues.empty? && (complete || peer) ? !!peer : nil
          records = recognized ? [ { component: "system", synchronized: synchronized,
            stratum: peer && peer[:stratum] < 16 ? peer[:stratum] + 1 : nil, reference: peer&.fetch(:peer_address),
            peer_address: peer&.fetch(:peer_address), offset_ms: nil, leap: nil } ] : []
          build_result(records, complete: complete, recognized: recognized, issues: issues, identity: [ :component ])
        end

        # 旧版本省略 VRF，新版本可能紧接 delay 后输出 VRF。
        def peer_row(line, number, vrf_column, issues)
          match = /\A([*+\-=])?\s*(\S+)\s+(\S+)\s+(\d+)\s+(\d+)\s+([0-7]+)\s+(.+)\z/.match(line)
          unless match
            issues << { code: :unparsed_row, line: number }
            return
          end
          if vrf_column.nil?
            issues << { code: :missing_ntp_header, line: number }
            return
          end

          remote, local = match.values_at(2, 3)
          raise ArgumentError if [ remote, local ].any? { |address| address.include?("/") || address.include?("%") }
          remote = IPAddr.new(remote).native.to_s
          IPAddr.new(local)
          stratum, reach = Integer(match[4], 10), Integer(match[6], 8)
          raise ArgumentError unless stratum.between?(0, 16) && reach <= 255

          delay = if vrf_column
            /\A(\d+(?:\.\d+)?)(?:\s+(\S+)|([^\d.\s]\S*))?\z/.match(match[7])
          else
            /\A(\d+(?:\.\d+)?)\z/.match(match[7])
          end
          raise ArgumentError unless delay && Float(delay[1]).finite?
          vrf = vrf_column ? delay[2] || delay[3] : nil
          raise ArgumentError if vrf_column && delay[3] && /\A[eE][+-]?\d+\z/.match?(delay[3])

          { peer_address: remote, vrf: vrf, selected: match[1] == "*", stratum: stratum, reachable: reach.positive? }
        rescue ArgumentError, IPAddr::InvalidAddressError
          issues << { code: :invalid_ntp_peer, line: number }
          nil
        end

        # 仅拼接文档明确的续行；未完成的记录不能吞并新的作用域。
        def each_ntp_line(source, issues)
          pending = nil
          source.each_line("\n").with_index(1) do |raw, number|
            line = raw.strip
            next if line.empty?

            if pending
              kind, prefix, first_line = pending
              continuation = kind == :header ? /\Ast\s+poll\s+reach\s+delay(?:\s+vrf)?\z/i : /\A\d+\s+\d+\s+[0-7]+\s+.+\z/
              pending = nil
              if continuation.match?(line)
                yield "#{prefix} #{line}", first_line
                next
              end
              issues << { code: kind == :header ? :truncated_ntp_header : :truncated_ntp_peer, line: first_line }
            end
            kind = if /\Aremote\s+local\z/i.match?(line)
              :header
            elsif /\A(?:[*+\-=]\s*)?[0-9a-f:.]+\s+[0-9a-f:.]+\z/i.match?(line)
              :peer_address
            end
            if kind
              pending = [ kind, line, number ]
            else
              yield line, number
            end
          end
          if pending
            issues << { code: pending[0] == :header ? :truncated_ntp_header : :truncated_ntp_peer, line: pending[2] }
          end
        end
      end
    end
  end
end
