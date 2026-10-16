# frozen_string_literal: true

require_relative "../../cisco_ios/parsers/show_interfaces"

module CtxChecker
  module CiscoNxos
    module Parsers
      # NX-OS 与 IOS 共享标签式计数器，但单独提供管理状态。
      class ShowInterface < CiscoIos::Parsers::ShowInterfaces
        PLATFORM = :cisco_nxos
        HEADER = /\A(\S+) is (administratively down|up|down|reset|deleted)(?:\s*\([^)]*\))?(?:, line protocol is (up|down)(?: \([^)]*\))?)?(?:, autostate (?:enabled|disabled))?\s*\z/i
        AUXILIARY = /\A(?:\d+ seconds? (?:input|output) rate\b|Auto-mdix is (?:turned )?(?:on|off)\z|Rate mode is \S+\z|EEE \(efficient-ethernet\)\s*:|admin fec state is \S+, oper fec state is \S+\z|L3 Switched:\z|(?:input|ucast): \d+ pkts, \d+ bytes - (?:output|mcast): \d+ pkts, \d+ bytes\z)/i
        DETAIL_METADATA = /\A(?:\d+ broadcast packets \d+ bytes|\d+ multicast frames \d+ compressed|No members|ucast: \d+ pkts, \d+ bytes)\z/i
        COUNTERS = CiscoIos::Parsers::ShowInterfaces::COUNTERS.merge(
          stomped_crc_errors: /(?<!\S)(\d+) Stomped\s+CRC(?=\s|\z)/i,
          out_carrier_errors: /(?<!\S)(\d+) out_carrier_errors(?=\s|\z)/i).freeze
        COUNTER_LABELS = CiscoIos::Parsers::ShowInterfaces::COUNTER_LABELS.merge(
          stomped_crc_errors: /\bStomped\s+CRC\b/i, out_carrier_errors: /\bout_carrier_errors\b/i).freeze

        private

        # NX-OS 的 SVI 头可附带 autostate，不改变协议状态语义。
        def interface_header(line) = HEADER.match(line)
        # 声明当前平台支持的接口错误与丢弃计数模式。
        def counter_patterns = COUNTERS
        # 将平台计数器标签映射到归一化指标名称。
        def counter_labels = COUNTER_LABELS
        # 识别包含接口计数测量值的数据行。
        def counter_line?(line) = COUNTER_LABELS.values.any? { |pattern| pattern.match?(line) } || super

        # CRC 总数已包含 stomped 帧，该子集应独立保留。
        def counter_source(line, metric)
          metric == :crc_errors ? line.gsub(/\bStomped\s+CRC\b/i, "stomped_checksum") : line
        end

        # NX-OS 在 SVI 运行状态头中报告明确的 shutdown 原因。
        def interface_record(match)
          super.tap do |record|
            record[:admin_status] = :down if match[0].match?(/\A\S+ is down\s*\(Administratively down\)/i)
          end
        end

        # 保留物理成员端口回显的聚合归属关系。
        def interface_detail(record, line)
          if (match = /\ABelongs to ((?:Po|port-channel)\d+)\z/i.match(line))
            record[:parent] = normalize_name(match[1])
          elsif record[:kind] == :aggregate && (match = /\AvPC Status: (Up|Down), vPC number: \d+(?: \[packets forwarded via vPC peer-link\])?\z/i.match(line))
            return record[:oper_status] == match[1].downcase.to_sym
          elsif /\Amgmt\d+\z/i.match?(record[:name]) && /\AManagement transceiver: (?:Absent|Present)\z/i.match?(line)
            (record[:management_metadata] ||= []) << :transceiver
          elsif /\Amgmt\d+\z/i.match?(record[:name]) && /\AActive connector: (?:RJ45|SFP)\z/i.match?(line)
            (record[:management_metadata] ||= []) << :connector
          else
            return false
          end
          true
        end

        # 部分管理接口表以连接器信息结尾，且仅提供包总数。
        def complete_counter_coverage(record, counters, issues)
          metadata = record.delete(:management_metadata)
          return super unless metadata == %i[transceiver connector] && counters.empty? && issues.empty?

          %i[in_errors out_errors crc_errors].map do |metric|
            { interface: record[:name], metric: metric, value: nil, discontinuity: nil }
          end
        end

        # 仅忽略已识别的描述字段；新出现的状态语法使结果保持部分完整。
        def auxiliary?(line)
          return false if line.match?(/\Aadmin state is\b/i)

          AUXILIARY.match?(line) || DETAIL_METADATA.match?(line) || super
        end
      end
    end
  end
end
