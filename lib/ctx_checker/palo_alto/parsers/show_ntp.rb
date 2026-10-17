# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module PaloAlto
    module Parsers
      # 对等体可达与 LOCAL 回退不能证明 NTP 已同步。
      class ShowNtp < CtxChecker::Parsers::Base
        private

        # 解析 show ntp，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          source = clean(text)
          rows, globals, issues = [], [], diagnostics
          current, fields, header, peer_fields = nil, {}, false, {}
          source.each_line.with_index(1) do |raw, number|
            line = raw.strip
            next if line.empty?
            if line == "NTP state:"
              header = true
            elsif (match = /\ANTP synched to (\S+)\z/i.match(line))
              globals << { component: "system", synchronized: !match[1].casecmp?("LOCAL"), reference: match[1] }
              current = nil
            elsif line.match?(/\ANTP not synched, using local clock\z/i)
              globals << { component: "system", synchronized: false, reference: "LOCAL" }
              current = nil
            elsif (match = /\ANTP server (\S+) connected: (True|False)\z/i.match(line))
              row = { component: "peer/#{match[1]}", peer: match[1], synchronized: nil }
              rows << row
              peer_fields[row.object_id] = { "reachable" => match[2].casecmp?("true") ? "yes" : "no" }
              current = nil
            elsif (match = /\ANTP server:\s*(\S+)\z/.match(line))
              current = { component: "peer/#{match[1]}", peer: match[1], synchronized: nil }
              rows << current
              fields = {}
              peer_fields[current.object_id] = fields
            elsif current && (match = /\A(status|reachable|authentication-type):\s*(\S+)\z/.match(line))
              key, value = match[1], match[2].downcase
              if fields.key?(key)
                issues << { code: :duplicate_ntp_field, line: number }
                current[:synchronized] = nil if key == "status"
              elsif key == "status"
                current[:synchronized] = { "synched" => true, "rejected" => false, "unsynched" => false }[value]
                # 可用备份对等体可以参与同步，但不是当前选中的同步源。
                issues << { code: :unknown_ntp_status, line: number } if current[:synchronized].nil? && value != "available"
              elsif key == "reachable" && !%w[yes no].include?(value)
                issues << { code: :unknown_ntp_reachability, line: number }
              end
              fields[key] = value
            else
              issues << { code: :unrecognized_ntp_row, line: number }
            end
          end
          rows.each do |row|
            if row[:synchronized] == true && peer_fields.fetch(row.object_id, {})["reachable"] == "no"
              row[:synchronized] = nil
              issues << { code: :conflicting_ntp_state, component: row[:component] }
            end
          end
          globals.each do |global|
            next unless global[:synchronized] == true
            peers = rows.select { |row| row[:peer] == global[:reference] }
            if peers.any? { |row| row[:synchronized] == false || peer_fields.fetch(row.object_id, {})["reachable"] == "no" }
              global[:synchronized] = nil
              issues << { code: :conflicting_ntp_state, component: "system" }
            end
          end
          if globals.empty? && header
            globals << { component: "system", synchronized: nil }
            issues << { code: :ntp_system_status_missing }
          end
          build_result(globals + rows, complete: complete, recognized: header && globals.any?, issues: issues, identity: [ :component ])
        end
      end
    end
  end
end
