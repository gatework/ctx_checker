# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module H3c
    module Parsers
      # Comware 接口块分别产生状态与计数器观测。
      class DisplayInterface < CtxChecker::Parsers::Base
        INTERFACE = /(?:[A-Za-z][A-Za-z-]*[\d\/.:]+|NULL\d+)/
        COUNTERS = {
          crc_errors: /(?<![\w.+-])(\d+) CRC\b/i,
          in_discards: /^[ \t]*(?:Input:[ \t]*\d+ packets?|\d+ packets? input),[ \t]*\d+ bytes?,[ \t]*(\d+) drops?[ \t]*$/i,
          out_discards: /^[ \t]*(?:Output:[ \t]*\d+ packets?|\d+ packets? output),[ \t]*\d+ bytes?,[ \t]*(\d+) drops?[ \t]*$/i
        }.freeze
        DISCARD_LABELS = { in_discards: /^[ \t]*(?:Input:|[^,\n]+ packets? input,).*\bdrops?\b/i, out_discards: /^[ \t]*(?:Output:|[^,\n]+ packets? output,).*\bdrops?\b/i }.freeze
        DETAILS = /\A(?:Current state:|Line protocol (?:current )?state:|Description:|Bandwidth:|Maximum |Allow jumbo|Broadcast |Multicast |Unicast |Known[ -]unicast |Internet |IP(?:v[46])? |Loopback |Media type |Port |[\w.-]+-speed mode|Link speed |Flow-control |The Maximum |Last |Current system time:|Peak |Input\b|Output\b|PVID:|MDI type:|Tagged VLANs:|UnTagged VLANs:|(?:\d+|-) (?:CRC|ignored|unicasts|aborts|lost carrier))/i
        NON_METRIC_DETAILS = /\A(?:Trunk port encapsulation:\s*IEEE 802\.1q|Physical:\s*(?:InLoopBack|Loopback|Unknown)|Physical(?:\s+is|:)\s*NULL DEV(?:, baudrate:\s*\d+ kbps)?)\z/i
        COUNTER_DETAILS = /\A(?:(?:\d+|-) (?:broadcasts,[ \t]*(?:\d+|-) multicasts(?:,[ \t]*(?:\d+|-) pauses)?|carrier,[ \t]*(?:\d+|-) no carrier|frame,[ \t]*(?:\d+|-) overruns,[ \t]*(?:\d+|-) aborts,[ \t]*(?:\d+|-) ignored,[ \t]*(?:\d+|-) parity errors)|\d+ packets? (?:input|output),[ \t]*\d+ bytes?,[ \t]*\d+ drops?)\z/i

        private

        # 接口状态独立于各配置块提供的计数器进行投影。
        def parse_output(text, complete:)
          text = clean(text)
          interfaces, counters, interface_issues, counter_issues = [], [], diagnostics, diagnostics
          sections = text.split(/(?=^[ \t]*#{INTERFACE}(?:[ \t]+current state[ \t]*:.*)?[ \t]*$)/i)
          sections.each do |section|
            header = /\A[ \t]*(#{INTERFACE})(?:[ \t]+current state[ \t]*:[ \t]*([^\n]+))?[ \t]*\n/i.match(section)
            next if section.strip.empty?
            unless header
              interface_issues << { code: :unrecognized_interface_block }
              next
            end
            name = CtxChecker::Parsers::InterfaceNames.normalize(header[1], platform: :h3c)
            unless known_details?(section)
              interface_issues << { code: :unrecognized_interface_field, interface: name }
            end
            states = [ header[2], *section.scan(/^[ \t]*Current state\s*:\s*(.+)$/i).flatten ].compact
            protocols = section.scan(/^[ \t]*Line protocol (?:current )?state\s*:\s*(.+)$/i).flatten
            if states.size > 1 || protocols.size > 1
              interface_issues << { code: :duplicate_interface_state, interface: name }
            end
            state = states.one? ? states.first : nil
            protocol = protocols.one? ? protocols.first : nil
            admin, oper = state_values(state)
            protocol = status(protocol)
            interface_issues << { code: :interface_state_missing, interface: name } if oper == :unknown || protocol == :unknown
            interfaces << { name: name, kind: CtxChecker::Parsers::InterfaceNames.kind(name), admin_status: admin,
              oper_status: oper, protocol_status: protocol, parent: name.include?(".") ? name.split(".").first : nil }
            # Never 或相对时间都不能证明跨重启的计数连续性。
            discontinuity = nil
            section_counters = []
            counter_source = section.lines("\n").reject { |line| /\A\s*Description:/i.match?(line) }.join("")
            COUNTERS.each do |metric, pattern|
              values = counter_source.scan(pattern).flatten
              if DISCARD_LABELS.key?(metric) && values.size != counter_source.scan(DISCARD_LABELS.fetch(metric)).size
                counter_issues << { code: :invalid_counter_value, interface: name, metric: metric }
                section_counters << { interface: name, metric: metric, value: nil, discontinuity: discontinuity }
                next
              end
              if values.one?
                section_counters << { interface: name, metric: metric, value: Integer(values.first, 10), discontinuity: discontinuity }
              elsif values.any?
                counter_issues << { code: :duplicate_counter, interface: name, metric: metric }
              end
            end
            if interfaces.last[:kind] == :physical
              missing = %i[in_discards out_discards crc_errors] - section_counters.map { |row| row[:metric] }
              missing.each { |metric| section_counters << { interface: name, metric: metric, value: nil, discontinuity: nil } }
              counter_issues << { code: :missing_counter_metrics, interface: name, metrics: missing } if missing.any?
            end
            counters.concat(section_counters)
          end
          CtxParser::Results.new(by_dimension: {
            interfaces: build_result(interfaces, complete: complete, recognized: interfaces.any?, issues: interface_issues, identity: [ :name ]),
            counters: build_result(counters, complete: complete, recognized: counters.any?, issues: counter_issues + interface_issues, identity: %i[interface metric])
          })
        end

        # 换行 VLAN 列表仅在紧接前一列表时作为元数据处理。
        def known_details?(section)
          vlan_list = false
          section.lines("\n").drop(1).all? do |raw|
            line = raw.strip
            if (match = /\A(?:VLAN (?:Passing|permitted)|(?:Tagged|Untagged)\s+VLAN ID)\s*:\s*(.+)\z/i.match(line))
              vlan_list = valid_vlan_list?(match[1])
            elsif vlan_list && /\A\s+\d/.match?(raw)
              valid_vlan_list?(line)
            else
              vlan_list = false
              line.empty? || DETAILS.match?(line) || NON_METRIC_DETAILS.match?(line) || COUNTER_DETAILS.match?(line)
            end
          end
        end

        # 校验 VLAN 元数据，避免任意数字尾行掩盖截断。
        def valid_vlan_list?(value)
          return true if value.casecmp?("none")

          value.split(/,\s*/, -1).all? do |token|
            match = /\A(\d+)(?:-(\d+))?(?:\(default vlan\))?\z/i.match(token)
            next false unless match
            first = match[1].to_i
            last = (match[2] || match[1]).to_i
            first.between?(1, 4094) && last.between?(first, 4094)
          end
        end

        # 区分主动管理关闭与已启用链路故障。
        def state_values(value)
          return [ :down, :down ] if value&.match?(/\AAdministratively\s+DOWN\b/i)
          observed = status(value)
          [ observed == :unknown ? :unknown : :up, observed ]
        end

        # 新出现或格式错误的状态文本明确保持未解析。
        def status(value)
          return :up if value&.match?(/\AUP(?:\s|\(|$)/i)
          return :down if value&.match?(/\A(?:DOWN|Administratively\s+DOWN|Link-Flap DOWN|mac-address moving down|MAD ShutDown|OFP DOWN|Storm-Constrain|STP DOWN|M-LAG MAD Shutdown)(?:\s|\(|$)/i)
          :unknown
        end
      end
    end
  end
end
