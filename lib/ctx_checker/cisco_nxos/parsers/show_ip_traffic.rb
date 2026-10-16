# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module CiscoNxos
    module Parsers
      # NX-OS 的 IPv4 软件协议栈标签不同于 IOS，需显式保留作用域。
      class ShowIpTraffic < CtxChecker::Parsers::Base
        METRICS = {
          "bad checksum" => [ "checksum_errors", :error ], "packet too small" => [ "packet_too_small", :error ],
          "bad version" => [ "bad_version", :error ], "bad header length" => [ "bad_header_length", :error ],
          "bad packet length" => [ "bad_packet_length", :error ], "bad destination" => [ "bad_destination", :error ],
          "bad ttl" => [ "bad_ttl", :error ], "could not forward" => [ "could_not_forward", :discard ],
          "no buffer dropped" => [ "no_buffer", :discard ], "bad encapsulation" => [ "encapsulation_failed", :discard ],
          "no route" => [ "no_route", :discard ], "non-existent protocol" => [ "unknown_protocol", :error ]
        }.freeze
        OPTIONAL_METRICS = {
          "stateful restart recovery" => [ "stateful_restart_recovery", :informational ],
          "mbuf pull up fail" => [ "mbuf_pullup_failed", :discard ],
          "bad options" => [ "bad_options", :error ], "bad context id" => [ "bad_context_id", :error ],
          "bad gw mac" => [ "bad_gateway_mac", :error ], "rpf drops" => [ "rpf_drops", :policy ],
          "vinci migration packets" => [ "vinci_migration_packets", :informational ],
          "total packet snooped" => [ "packets_snooped", :informational ],
          "total packet on down svi" => [ "packets_on_down_svi", :informational ],
          "ingress option processing failed" => [ "ingress_option_processing_failed", :discard ],
          "nat inside drop" => [ "nat_inside_drops", :discard ], "nat outside drop" => [ "nat_outside_drops", :discard ],
          "ingress mforward failed" => [ "ingress_mforward_failed", :discard ],
          "ingress lisp drop" => [ "ingress_lisp_drops", :discard ],
          "ingress lisp decap drop" => [ "ingress_lisp_decap_drops", :discard ],
          "ingress lisp encap drop" => [ "ingress_lisp_encap_drops", :discard ],
          "ingress lisp encap" => [ "ingress_lisp_encapsulated", :informational ],
          "ingress mfwd copy drop" => [ "ingress_mfwd_copy_drops", :discard ],
          "ingress ra/reass drop" => [ "ingress_ra_reass_drops", :discard ],
          "ingress icmp redirect processing drop" => [ "ingress_icmp_redirect_processing_drops", :discard ],
          "ingress drop (ifmgr init)" => [ "ingress_ifmgr_init_drops", :discard ],
          "ingress drop (invalid filter)" => [ "ingress_invalid_filter_drops", :discard ],
          "ingress drop (invalid l2 msg)" => [ "ingress_invalid_l2_message_drops", :discard ]
        }.freeze
        ERROR_METRICS = METRICS.merge(OPTIONAL_METRICS).freeze
        ERROR_LABELS = Regexp.union((ERROR_METRICS.keys - [ "bad gw mac" ]).sort_by { |label| -label.size })
        ERROR_CELL = /\G\s*(?:,\s*)?(?:(#{ERROR_LABELS.source})\s*:\s*|(bad gw mac)\s+)(\d+)(?=\s|,|\z)/i
        ACL_METRICS = { "ingress" => "acl_ingress_drops", "egress" => "acl_egress_drops",
          "directed broadcast" => "acl_directed_broadcast_drops" }.freeze
        FRAGMENT_METRICS = {
          "fragments dropped" => [ "fragments_dropped", :discard ],
          "fragments timed out" => [ "fragments_timed_out", :discard ]
        }.freeze
        FRAGMENT_CONTEXT = [ "fragments received", "fragments sent", "fragments created", "packets with df", "packets reassembled" ].freeze

        private

        # 解析 show ip traffic，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          records, issues = [], []
          recognized = false
          section = nil
          fragment_sections, acl_sections = 0, 0
          ipv4 = false
          clean(text).each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty?
            if /\AIP Software Processed Traffic Statistics\z/i.match?(line)
              ipv4 = recognized = true
              section = nil
            elsif /\A(?:ICMP|TCP|UDP|IPv6)\s/i.match?(line)
              ipv4 = false
              section = nil
            elsif ipv4 && /\AErrors:\z/i.match?(line)
              section = :errors
            elsif ipv4 && /\AFragmentation\/reassembly:\z/i.match?(line)
              section = :fragments
              fragment_sections += 1
            elsif ipv4 && /\AACL Filter Drops\s*:\z/i.match?(line)
              section = :acl
              acl_sections += 1
            elsif ipv4 && /\AFragments created per protocol\z/i.match?(line)
              section = :fragment_protocols
            elsif /\A(?:Multicast|IP output|IP input|Rcvd|Sent|Input|Output|Statistics last reset)(?:\s|:)/i.match?(line)
              section = nil
            elsif section == :errors
              parse_error_counters(line, number, records, issues)
            elsif section == :acl
              parse_acl_counter(line, number, records, issues)
            elsif section == :fragment_protocols
              issues << { code: :unparsed_counter, line: number } unless /\A\d+\s*:\s*\d+\z/.match?(line)
            elsif section == :fragments
              line.delete_suffix(",").split(/,\s*/).each do |cell|
                match = /\A([^:]+):\s*(\d+)\z/.match(cell)
                label = match && match[1].downcase
                definition = FRAGMENT_METRICS[label]
                if definition
                  records << counter(definition, match[2])
                elsif !FRAGMENT_CONTEXT.include?(label)
                  issues << { code: :unparsed_counter, line: number }
                end
              end
            end
          end
          missing = METRICS.values.map(&:first) - records.map { |record| record[:metric] }
          issues << { code: :counter_fields_missing, count: missing.size } if recognized && missing.any?
          if fragment_sections.positive?
            missing = FRAGMENT_METRICS.values.map(&:first) - records.map { |record| record[:metric] }
            issues << { code: :fragment_counter_fields_missing, count: missing.size } if missing.any?
            issues << { code: :duplicate_counter_section, scope: "fragmentation" } if fragment_sections > 1
          end
          if acl_sections.positive?
            missing = ACL_METRICS.values - records.map { |record| record[:metric] }
            issues << { code: :acl_counter_fields_missing, count: missing.size } if missing.any?
            issues << { code: :duplicate_counter_section, scope: "acl" } if acl_sections > 1
          end
          build_result(records, complete: complete, recognized: recognized, issues: issues, identity: %i[component metric])
        end

        # NX-OS 的部分相邻错误字段不以逗号分隔，且某个标签可能重复出现。
        def parse_error_counters(line, number, records, issues)
          position = 0
          until /\A\s*,?\s*\z/.match?(line[position..])
            match = ERROR_CELL.match(line, position)
            unless match
              issues << { code: :unparsed_counter, line: number }
              break
            end
            definition = ERROR_METRICS.fetch((match[1] || match[2]).downcase)
            record = counter(definition, match[3])
            # 仅允许此类已知重复 NX-OS 展示字段合并相同值。
            repeated = record[:metric] == "ingress_option_processing_failed" && records.include?(record)
            records << record unless repeated
            position = match.end(0)
          end
        end

        # ACL 过滤属于主动策略，不能作为通用硬件错误总数。
        def parse_acl_counter(line, number, records, issues)
          match = /\A(Ingress|Egress|Directed Broadcast)\s+-\s+(\d+)\z/i.match(line)
          if match
            records << counter([ ACL_METRICS.fetch(match[1].downcase), :policy ], match[2])
          else
            issues << { code: :unparsed_counter, line: number }
          end
        end

        # 提取支持的累计计数器，不强制转换未知值。
        def counter(definition, value)
          { component: "ipv4/control_plane", metric: definition[0], category: definition[1],
            value: Integer(value, 10), discontinuity: nil }
        end
      end
    end
  end
end
