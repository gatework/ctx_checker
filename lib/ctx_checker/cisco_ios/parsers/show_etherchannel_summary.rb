# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module CiscoIos
    module Parsers
      # 保留聚合父接口与成员状态，包括合法的 LACP 备用成员。
      class ShowEtherchannelSummary < CtxChecker::Parsers::Base
        PLATFORM = :cisco_ios
        MEMBER_STATES = { "P" => :active, "H" => :standby, "D" => :down, "s" => :suspended,
          "I" => :unselected, "w" => :unselected, "M" => :unselected, "r" => :down, "p" => :active,
          "b" => :unselected }.freeze

        private

        # 要求存在数据表或明确空表证据；标志图例不能作为成员记录。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues, groups, totals = [], diagnostics, [], []
          current, header, empty = nil, false, false
          text.each_line.with_index(1) do |source, number|
            line = source.strip
            next if line.empty? || line.match?(/\A[-=+ ]+\z/)

            if line.match?(/\AGroup\s+Port-(?:channel|Channel)?\s+(?:Type\s+)?Protocol\s+(?:Ports|Member Ports)\z/i)
              header = true
            elsif (match = /\A(\d+)\s+((?:Po|port-channel)\d+)\(([^()\s]+)\)\s+(?:(?:Eth|FC)\s+)?(?:LACP|PAgP|NONE|--|-|None)\s*(.*)\z/i.match(line))
              current = { group: normalize_name(match[2]), oper_status: group_state(match[3], issues, number) }
              groups << current
              append_members(rows, current, match[4], issues, number)
            elsif line.match?(/\A\d+\s+(?:Po|port-channel)\d+\b/i)
              current = nil
              issues << { code: :unparsed_aggregation_group, line: number }
            elsif current && line.match?(/\A\S+\s*\([^()\s]+\)/)
              append_members(rows, current, line, issues, number)
            elsif (match = /\ANumber of (?:port-channels|channel-groups in use):\s*(\d+)\z/i.match(line))
              totals << Integer(match[1], 10)
              empty ||= match[1] == "0"
            elsif line.match?(/\ANo (?:port-channels|channel-groups|EtherChannels)(?: found)?\.?\z/i)
              empty = true
            elsif legend?(line)
              next
            else
              issues << { code: :unparsed_row, line: number }
            end
          end
          totals.each do |total|
            issues << { code: :count_mismatch, expected: total, observed: groups.size } unless total == groups.size
          end
          member_groups = rows.to_h { |row| [ row[:group], true ] }
          groups.each do |group|
            next if member_groups.key?(group[:group])

            rows << group.merge(member: nil, member_status: :unknown)
            member_groups[group[:group]] = true
            issues << { code: :aggregation_members_missing, group: group[:group] }
          end
          repeated_groups = groups.group_by { |group| group[:group] }.select { |_, entries| entries.size > 1 }.keys
          if repeated_groups.any?
            issues << { code: :duplicate_aggregation_group, count: repeated_groups.size }
            repeated = repeated_groups.to_h { |name| [ name, true ] }
            rows.reject! { |row| repeated.key?(row[:group]) }
          end
          issues << { code: :contradictory_empty } if empty && groups.any?
          build_result(rows, complete: complete, recognized: empty || (header && groups.any?), issues: issues, identity: %i[group member])
        end

        # 将物理成员关联到其逻辑聚合接口。
        def append_members(rows, group, text, issues, number)
          return if text.empty?
          if text == "--"
            rows << group.merge(member: nil, member_status: :unknown)
            return
          end

          text.scan(/[^\s()]+\s*\([^()\s]+\)|\S+/).each do |word|
            match = /\A([^()\s]+)\s*\(([^()\s]+)\)\z/.match(word)
            unless match
              issues << { code: :unparsed_member, line: number }
              next
            end
            state = MEMBER_STATES.fetch(match[2], :unknown)
            issues << { code: :unknown_member_status, line: number } if state == :unknown
            rows << group.merge(member: normalize_name(match[1]), member_status: state)
          end
        end

        # 归一化聚合组报告的运行状态。
        def group_state(flags, issues, number)
          unless flags.match?(/\A[SRUDM]+\z/) && !(flags.include?("U") && (flags.include?("D") || flags.include?("M")))
            issues << { code: :unknown_aggregation_status, line: number }
            return :unknown
          end
          return :down if flags.include?("D") || flags.include?("M")
          return :up if flags.include?("U")

          issues << { code: :unknown_aggregation_status, line: number }
          :unknown
        end

        # 识别表格图例，避免将其作为资源记录。
        def legend?(line)
          line == "Channel" || line.match?(/\A(?:Flags:|[A-Za-z] - |[A-Za-z]\s+-\s+|Number of aggregators:|Number of aggregators in use:)/)
        end

        # 将接口别名归一化为平台标准身份。
        def normalize_name(name) = CtxChecker::Parsers::InterfaceNames.normalize(name, platform: self.class::PLATFORM)
      end
    end
  end
end
