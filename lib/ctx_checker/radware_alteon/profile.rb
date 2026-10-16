# frozen_string_literal: true

require "ctx_parser/profile"
require_relative "../observation"
require_relative "parsers/info_link"
require_relative "parsers/info_l3_ip"
require_relative "parsers/info_transceiver"
require_relative "parsers/info_l2_trunk"
require_relative "parsers/info_l2_lacp_dump"
require_relative "parsers/stats_port_if"
require_relative "parsers/stats_port_ether"
require_relative "parsers/info_l3_bgp_summary"
require_relative "parsers/info_l3_ospf_nbr"
require_relative "parsers/stats_mp_cpu"
require_relative "parsers/stats_mp_mem"
require_relative "parsers/stats_sp_allutils"
require_relative "parsers/info_sys_temp"
require_relative "parsers/info_sys_fan"
require_relative "parsers/info_sys_ps"
require_relative "parsers/info_sys_general"
require_relative "parsers/stats_sys_ntp"

module CtxChecker
  module RadwareAlteon
    # Alteon 菜单查询独立于其他 Radware 产品系列。
    class Profile < CtxParser::Profile
      MAX_DISCOVERED_PORTS = 256
      CATALOG = CtxParser::CommandCatalog.new([
        { dimensions: [ :interfaces ], command: "/info/link", parser: Parsers::InfoLink },
        { dimensions: [ :interfaces ], command: "/info/l3/ip", parser: Parsers::InfoL3Ip },
        { dimensions: [ :aggregation ], command: "/info/l2/trunk", parser: Parsers::InfoL2Trunk },
        { dimensions: [ :aggregation ], command: "/info/l2/lacp/dump", parser: Parsers::InfoL2LacpDump },
        { dimensions: [ :bgp ], command: "/info/l3/bgp/summary", parser: Parsers::InfoL3BgpSummary },
        { dimensions: [ :ospf ], command: "/info/l3/ospf/nbr", parser: Parsers::InfoL3OspfNbr },
        { dimensions: [ :cpu ], command: "/stats/mp/cpu", parser: Parsers::StatsMpCpu },
        { dimensions: [ :memory ], command: "/stats/mp/mem", parser: Parsers::StatsMpMem },
        { dimensions: %i[cpu memory], command: "/stats/sp 1/allutils", parser: Parsers::StatsSpAllutils },
        { dimensions: [ :temperature ], command: "/info/sys/temp", parser: Parsers::InfoSysTemp },
        { dimensions: [ :environment ], command: "/info/sys/fan", parser: Parsers::InfoSysFan },
        { dimensions: [ :power ], command: "/info/sys/ps", parser: Parsers::InfoSysPs },
        { dimensions: [ :clock ], command: "/info/sys/general", parser: Parsers::InfoSysGeneral },
        { dimensions: %i[ntp device_counters], command: "/stats/sys/ntp", parser: Parsers::StatsSysNtp }
      ], multi_command: true)
      COMMANDS = CATALOG.commands
      PARSERS = CATALOG.parsers

      # 打开连接器前，拒绝已知不兼容的产品系列。
      def initialize(model: nil)
        super
        raise ArgumentError, "DefensePro requires a separate checker profile" if /defen[cs]e[\s_-]*pro/i.match?(model.to_s)

        @catalog = CATALOG
      end

      # 扩展后的实例保留不可变命令与实现索引。
      def commands = @catalog.commands

      # 绑定端口的解析器复用基础型号覆盖及命令选择契约。
      def parsers = @catalog.parsers

      # 已知光模块命令缺陷根据固件事实判断，不依据型号名称猜测。
      def with_software_version(value)
        raise ArgumentError, "Software version must be text" unless value.nil? || value.is_a?(String)

        entries = @catalog.entries.reject { |entry| entry[:dimensions].include?(:optics) }
        if transceiver_fixed?(value)
          entries += [ { dimensions: [ :optics ], command: "/info/transceiver", parser: Parsers::InfoTransceiver } ]
        end
        expanded = dup
        expanded.instance_variable_set(:@catalog, CtxParser::CommandCatalog.new(entries, multi_command: true))
        expanded
      end

      # Alteon 不提供全端口叶级查询，计数器采集必须依赖完整端口清单。
      def discovery_dimensions(requested)
        requested.include?(:counters) ? [ :interfaces ] : []
      end

      # 仅为经过校验的清单端口生成查询；发现不完整时不猜测端口。
      def expand(observations, dimensions:)
        return self unless dimensions.include?(:counters) && !commands.key?(:counters)

        interfaces = observations[:interfaces]
        return self unless physical_source_complete?(interfaces)

        ports = discovered_ports(interfaces)
        return self if ports.empty?

        additions = ports.flat_map do |port|
          [ { dimensions: [ :counters ], command: "/stats/port #{port}/if", parser: Parsers::StatsPortIf.for_port(port) },
            { dimensions: [ :counters ], command: "/stats/port #{port}/ether", parser: Parsers::StatsPortEther.for_port(port) } ]
        end
        expanded = dup
        expanded.instance_variable_set(:@catalog, CtxParser::CommandCatalog.new(@catalog.entries + additions, multi_command: true))
        expanded
      end

      # 每个发现端口均需标准计数器和以太网错误计数器证据。
      def counter_metrics = %i[in_errors out_errors in_discards out_discards crc_errors out_carrier_errors].freeze

      private

      # 官方修复版本为 30.5.9.0、31.0.6.0、32.1.0.0；其他版本分支保持不可用。
      def transceiver_fixed?(value)
        return false unless /\A(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\z/.match?(value.to_s)

        major, minor, patch, build = value.split(".").map { |part| Integer(part, 10) }
        case [ major, minor ]
        when [ 30, 5 ] then ([ patch, build ] <=> [ 9, 0 ]) >= 0
        when [ 31, 0 ] then ([ patch, build ] <=> [ 6, 0 ]) >= 0
        else major == 32 && minor >= 1
        end
      end

      # 逻辑接口证据失败不能使完整物理接口清单失效。
      def physical_source_complete?(interfaces)
        return false unless interfaces.is_a?(Observation) && interfaces.name == :interfaces && %i[complete partial].include?(interfaces.status)

        sources = interfaces.evidence.select { |entry| entry[:command] == "/info/link" }
        sources.one? && sources.first[:status] == :complete && interfaces.records.all? do |row|
          !row[:name].start_with?("port") || row[:source_complete] == true
        end
      end

      # 限制动态查询范围，不将数字后缀视为任意 CLI 文本。
      def discovered_ports(interfaces)
        ports = interfaces.records.filter_map do |row|
          next unless row[:kind] == :physical
          name = row[:name]
          next unless name.start_with?("port")

          match = /\Aport([1-9]\d*)\z/.match(name)
          port = Integer(match[1], 10) if match
          unless port && port <= MAX_DISCOVERED_PORTS
            raise ArgumentError, "Invalid discovered Alteon port identity"
          end
          port
        end.uniq.sort
        raise ArgumentError, "Alteon port discovery exceeds the query limit" if ports.size > MAX_DISCOVERED_PORTS

        ports
      end
    end
  end
end
