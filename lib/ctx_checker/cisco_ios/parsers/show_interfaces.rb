# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"
require "ctx_parser/results"

module CtxChecker
  module CiscoIos
    module Parsers
      # 同一接口详细回显分别提供状态与计数器观测。
      class ShowInterfaces < CtxChecker::Parsers::Base
        PLATFORM = :cisco_ios
        HEADER = /\A(\S+) is (administratively down|up|down|reset|deleted)(?:, line protocol is (up|down)(?: \([^)]*\))?)?(?:\s*\([^)]*\))?(?:\s*,\s*Autostate (?:Enabled|Disabled))?\s*\z/i
        COUNTERS = { in_errors: /(?<!\S)(\d+) input errors?\b/i, out_errors: /(?<!\S)(\d+) output errors?\b/i,
          crc_errors: /(?<!\S)(\d+) CRC(?:\/FCS)?\b/i, in_discards: /(?<!\S)(\d+) input discards?\b/i,
          out_discards: /(?<!\S)(\d+) output discards?\b/i }.freeze
        COUNTER_LABELS = { in_errors: /\binput errors?\b/i, out_errors: /\boutput errors?\b/i,
          crc_errors: /\bCRC(?:\/FCS)?\b/i, in_discards: /\binput discards?\b/i, out_discards: /\boutput discards?\b/i }.freeze
        AUXILIARY = /\A(?:Hardware[: ]|Description:|Internet address|MTU |reliability |Encapsulation |Keepalive |Full-duplex|Half-duplex|full-duplex|half-duplex|Auto-duplex|auto-duplex|Input flow-control|Output flow-control|ARP type:|Last input |Last clearing |Input queue:|Output queue:|Queueing strategy:|[\d ]+(?:second|minute) (?:input|output) rate|[\d ]+(?:packets input|packets output|bytes|no buffer|broadcasts|multicasts|runts|giants|watchdog|output buffer|lost carrier|unknown protocol drops|interface resets|carrier transitions|collisions|babbles|underruns)|Received |Output feature|L2 Switched:|L3 in Switched:|L3 out Switched:|Port mode is |Beacon is |Auto-Negotiation is |FEC mode is |Flowcontrol|Switchport monitor|EtherType is |Members in this channel:|Last link flapped |Last link change |Last input change |[\d ]+interface resets|Load-Interval |Input rate |Output rate |RX\z|TX\z|[\d ]+(?:unicast packets|input packets|output packets|jumbo packets|Rx pause|Tx pause|storm suppression)|Tunnel |tunnel |Transport |Destination |Source |DTR is |[\d ]+packets,|BW |Mode is |IP address is |Port-channel is |admin state is |[\d ]+bad etype drop|Last clearing of)/i

        private

        # 分别跟踪覆盖率；有效状态头不能证明计数器已采集。
        def parse_output(text, complete:)
          text = clean(text)
          interfaces, counters, state_issues, counter_issues = [], [], diagnostics, diagnostics
          current = nil
          states = {}
          text.each_line("\n").with_index(1) do |source, number|
            line = source.strip
            next if line.empty?

            if (match = interface_header(line))
              current = interface_record(match)
              states = current.slice(:admin_status, :protocol_status).transform_values { |value| value == :unknown ? [] : [ value ] }
              interfaces << current
            elsif (match = /\A(\S+) is /.match(line)) && CtxChecker::Parsers::InterfaceNames.kind(normalize_name(match[1])) != :unknown
              current = nil
              state_issues << { code: :unparsed_interface_header, line: number }
            elsif current && (match = /\Aadmin state is (up|down)\b/i.match(line))
              assign_state(current, :admin_status, match[1].downcase.to_sym, states, state_issues, number)
            elsif current && (match = /\ALine protocol is (up|down)\b/i.match(line))
              assign_state(current, :protocol_status, match[1].downcase.to_sym, states, state_issues, number)
            elsif current && (match = /\ALast clearing of "show interfaces?" counters\s+(.+)\z/i.match(line))
              # 相对清零时长不能证明两个采样间的计数器连续性。
              current[:discontinuity] = nil
            elsif current && /\ADescription:/i.match?(line)
              next
            elsif current && counter_line?(line)
              found = counter_patterns.flat_map do |metric, pattern|
                source = counter_source(line, metric)
                values = source.scan(pattern).flatten
                if values.size != source.scan(counter_labels.fetch(metric)).size
                  counter_issues << { code: :invalid_counter_value, metric: metric, line: number }
                end
                values.map { |value| { interface: current[:name], metric: metric, value: Integer(value, 10), discontinuity: nil } }
              end
              output_drops = line.scan(/\bTotal output drops:\s*(\d+)(?=\s*(?:;|\z))/i).flatten
              output_drops.each do |value|
                # IOS-XE 此处可能显示字节数或包数，取决于平台配置。
                found << { interface: current[:name], metric: :out_discards, value: Integer(value, 10), discontinuity: nil,
                  unit: :unknown, scope: :queue }
              end
              if output_drops.size != line.scan(/\bTotal output drops:/i).size
                counter_issues << { code: :invalid_counter_value, metric: :out_discards, line: number }
              end
              if (match = /\AInput queue:\s*\d+\/\d+\/(\d+)(?:\/\d+)?\s+\(size\/max\/drops(?:\/flushes)?\)/i.match(line))
                found << { interface: current[:name], metric: :in_discards, value: Integer(match[1], 10), discontinuity: nil,
                  unit: :packets, scope: :queue }
              elsif line.match?(/\AInput queue:.*drops/i)
                counter_issues << { code: :invalid_counter_value, metric: :in_discards, line: number }
              end
              counters.concat(found)
              counter_issues << { code: :unparsed_counter, line: number } if found.empty?
            elsif current && interface_detail(current, line)
              next
            elsif current && auxiliary?(line)
              next
            else
              state_issues << { code: :unparsed_row, line: number }
            end
          end
          discontinuities = interfaces.to_h { |record| [ record[:name], record.delete(:discontinuity) ] }
          counters.each { |record| record[:discontinuity] = discontinuities[record[:interface]] }
          counters_by_interface = counters.group_by { |counter| counter[:interface] }
          interfaces.select { |record| record[:kind] == :physical }.each do |record|
            counters.concat(complete_counter_coverage(record, counters_by_interface.fetch(record[:name], []), counter_issues))
          end
          CtxParser::Results.new(by_dimension: {
            interfaces: build_result(interfaces, complete: complete, recognized: interfaces.any?, issues: state_issues, identity: [ :name ]),
            counters: build_result(counters, complete: complete, recognized: counters.any?, issues: state_issues + counter_issues,
              identity: %i[interface metric])
          })
        end

        # 冲突协议状态保留 down；冲突管理状态不能据此豁免接口检查。
        def assign_state(record, field, value, states, issues, number)
          values = states.fetch(field)
          values << value unless values.include?(value)
          record[field] = if values.size > 1
            issues << { code: :conflicting_interface_state, field: field, interface: record[:name], line: number }
            field == :protocol_status ? :down : :unknown
          else
            value
          end
        end

        # 按计数器标签匹配，不误取总包数，并保留格式错误的指标行。
        def counter_line?(line)
          line.match?(/\b(?:input errors?|output errors?|CRC(?:\/FCS)?|input discards?|output discards?|Total output drops)\b/i) ||
            line.match?(/\AInput queue:.*drops/i)
        end

        # 将接口别名归一化为平台标准身份。
        def normalize_name(name) = CtxChecker::Parsers::InterfaceNames.normalize(name, platform: self.class::PLATFORM)

        # 平台语法覆盖独立于公共计数器提取逻辑。
        def interface_header(line) = HEADER.match(line)
        # 将平台特有的详细行留给子类扩展点处理。
        def interface_detail(_record, _line) = false
        # 识别说明性回显，不将其作为数据记录。
        def auxiliary?(line)
          AUXILIARY.match?(line) || /\AOutput \d+ broadcasts \(\d+ (?:IP )?multicasts\)\z/i.match?(line) ||
            /\AUnknown, Unknown, link type is \S+, media type is \S+\z/i.match?(line) || /\AFec is \S+\z/i.match?(line)
        end
        # 声明当前平台支持的接口错误与丢弃计数模式。
        def counter_patterns = COUNTERS
        # 将平台计数器标签映射到归一化指标名称。
        def counter_labels = COUNTER_LABELS
        # 标记这些计数测量来自哪个命令视图。
        def counter_source(line, _metric) = line

        # 物理端口健康需要明确的错误包与 CRC 测量证据。
        def complete_counter_coverage(record, counters, issues)
          missing = %i[in_errors out_errors crc_errors] - counters.map { |counter| counter[:metric] }
          issues << { code: :counter_fields_missing, interface: record[:name], metrics: missing } if missing.any?
          []
        end

        # 复用接口头字段及子接口身份，不虚构协议状态。
        def interface_record(match)
          name = normalize_name(match[1])
          record = { name: name, kind: CtxChecker::Parsers::InterfaceNames.kind(name),
            admin_status: match[2].casecmp?("administratively down") ? :down : :unknown,
            oper_status: match[2].casecmp?("up") ? :up : :down,
            protocol_status: match[3]&.downcase&.to_sym || :unknown, parent: nil }
          record[:admin_status] = :up if self.class::PLATFORM == :cisco_ios && record[:admin_status] != :down
          record[:parent] = name.split(".", 2).first if record[:kind] == :subinterface
          record
        end
      end
    end
  end
end
