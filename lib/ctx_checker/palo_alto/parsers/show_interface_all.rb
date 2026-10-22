# frozen_string_literal: true

require_relative "../../parsers/base"
require_relative "../../parsers/interface_names"

module CtxChecker
  module PaloAlto
    module Parsers
      # PAN-OS 分别展示物理状态与逻辑接口清单。
      class ShowInterfaceAll < CtxChecker::Parsers::Base
        private

        # 解析 show interface all，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          text = clean(text)
          rows, issues, section, totals, counts, duplicates = {}, diagnostics, nil, {}, Hash.new(0), []
          logical_names = {}
          text.each_line("\n") do |raw|
            line = raw.strip
            if (match = /\Atotal configured (hardware|logical) interfaces:\s*(\d+)\z/i.match(line))
              section = match[1].downcase.to_sym
              declare_total(totals, section, match[2].to_i, issues)
            elsif (match = /\Aaggregation groups:\s*(\d+)\z/i.match(line))
              section = :aggregation
              declare_total(totals, section, match[1].to_i, issues)
            elsif line.empty? || line.match?(/\A[- ]+\z/) || line.match?(/\Aname\s+id\s+/i)
              next
            elsif section == :hardware && (match = /\A(\S+)\s+\d+\s+\S+\/\S+\/(up|down)(?:\([^\s]*\))?\s+[\da-f:]+\z/i.match(line))
              name = CtxChecker::Parsers::InterfaceNames.normalize(match[1], platform: :palo_alto)
              if rows.key?(name)
                issues << { code: :duplicate_interface, interface: name }
                duplicates << name
              end
              rows[name] = record(name).merge(oper_status: match[2].downcase.to_sym)
              counts[section] += 1
            elsif section == :aggregation && line.match?(/\Aae\d+ members:\z/i)
              counts[section] += 1
            elsif section == :aggregation && line.match?(/\Aethernet\d+\/\d+(?:\s+ethernet\d+\/\d+)*\z/i)
              next # 清单中的成员关系不表示 LACP 选中状态或运行状态。
            elsif section == :logical && (match = /\A(\S+)\s+\d+\s+\d+\s+.+\z/.match(line))
              name = CtxChecker::Parsers::InterfaceNames.normalize(match[1], platform: :palo_alto)
              if logical_names.key?(name)
                issues << { code: :duplicate_interface, interface: name }
                duplicates << name
              end
              logical_names[name] = true
              rows[name] ||= record(name)
              counts[section] += 1
            elsif section == :logical && line.match?(%r{\A[\da-f:.]+/\d+\z}i)
              next # 地址续行不携带接口状态。
            else
              issues << { code: :unrecognized_interface_line }
            end
          end
          totals.each do |kind, total|
            issues << { code: :count_mismatch, section: kind, expected: total, observed: counts[kind] } if total != counts[kind]
          end
          duplicates.each { |name| rows.delete(name) }
          build_result(rows.values, complete: complete, recognized: totals.key?(:hardware), issues: issues, identity: [ :name ])
        end

        # 同一作用域的矛盾声明不能被末次总数覆盖。
        def declare_total(totals, section, total, issues)
          if totals.key?(section) && totals[section] != total
            issues << { code: :conflicting_count, section: section }
          else
            totals[section] = total
          end
        end

        # 先创建状态未知的接口身份，再由所属表补充明确证据。
        def record(name)
          { name: name, kind: CtxChecker::Parsers::InterfaceNames.kind(name), admin_status: :unknown, oper_status: :unknown,
            protocol_status: :unknown, parent: name.match?(/\A(?:ethernet|ae).*\./) ? name.split(".").first : nil }
        end
      end
    end
  end
end
