# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module CiscoIos
    module Parsers
      # IP 协议栈计数为累计值，与 ASIC 和接口计数区分处理。
      class ShowIpTraffic < CtxChecker::Parsers::Base
        METRICS = {
          "format errors" => [ "format_errors", :error ], "checksum errors" => [ "checksum_errors", :error ],
          "bad hop count" => [ "bad_ttl", :error ], "unknown protocol" => [ "unknown_protocol", :error ],
          "not a gateway" => [ "not_a_gateway", :discard ], "security failures" => [ "security_failures", :policy ],
          "bad options" => [ "bad_options", :error ], "encapsulation failed" => [ "encapsulation_failed", :discard ],
          "unresolved" => [ "unresolved", :discard ], "no adjacency" => [ "no_adjacency", :discard ],
          "no route" => [ "no_route", :discard ], "unicast RPF" => [ "unicast_rpf", :policy ],
          "forced drop" => [ "forced_drop", :discard ], "options denied" => [ "options_denied", :policy ],
          "source IP address zero" => [ "source_address_zero", :discard ],
          "ignored" => [ "options_ignored", :policy ], "invalid hole" => [ "invalid_hole", :error ],
          "unsupported-addr" => [ "unsupported_address", :discard ],
          "timeouts" => [ "reassembly_timeouts", :error ], "couldn't reassemble" => [ "reassembly_failed", :error ],
          "couldn't fragment" => [ "fragmentation_failed", :error ]
        }.freeze
        INFORMATIONAL = /\A\d+ (?:total|local destination|with options|end|nop|basic security|loose source route|timestamp|extended security|record route|stream ID|strict source route|alert|cipso|ump|other|reassembled|fragmented|fragments|received|sent|generated|forwarded)\z/i
        REQUIRED_METRICS = %w[format_errors checksum_errors bad_ttl unknown_protocol encapsulation_failed no_route].freeze

        private

        # 解析 show ip traffic，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          records, issues = [], diagnostics
          active = false
          recognized = false
          clean(text).each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty?
            if line == "IP statistics:"
              active = recognized = true
              next
            end
            if /\A\S+ statistics:/.match?(line)
              active = false
              next
            end
            next unless active

            line.sub(/\A(?:Rcvd|Opts|Frags|Bcast|Mcast|Sent|Drop):\s*/, "").split(/,\s*/).each do |cell|
              match = /\A(\d+) (.+)\z/.match(cell)
              definition = match && METRICS[match[2]]
              if definition
                records << { component: "ipv4/control_plane", metric: definition[0], category: definition[1],
                  value: Integer(match[1], 10), discontinuity: nil }
              elsif !INFORMATIONAL.match?(cell)
                issues << { code: :unparsed_counter, line: number }
              end
            end
          end
          missing = REQUIRED_METRICS - records.map { |record| record[:metric] }
          issues << { code: :counter_fields_missing, count: missing.size } if recognized && missing.any?
          build_result(records, complete: complete, recognized: recognized, issues: issues, identity: %i[component metric])
        end
      end
    end
  end
end
