# frozen_string_literal: true

require "ctx_parser/profile"
require_relative "parsers/show_interface"
require_relative "parsers/show_interface_counter"
require_relative "parsers/show_transceiver"
require_relative "parsers/show_ip_bgp_summary"
require_relative "parsers/show_ip_ospf_neighbor"
require_relative "parsers/show_cpu"
require_relative "parsers/show_memory"
require_relative "parsers/show_environment"
require_relative "parsers/show_clock"
require_relative "parsers/show_ntp_status"
require_relative "parsers/show_cpu_cntr"

module CtxChecker
  module Hillstone
    # StoneOS 命令已在 SG-6000-A3700 验证；未覆盖作用域明确保留不可用。
    class Profile < CtxParser::Profile
      CATALOG = CtxParser::CommandCatalog.new([
        { dimensions: %i[interfaces aggregation], command: "show interface", parser: Parsers::ShowInterface },
        { dimensions: [ :counters ], command: "show interface counter", parser: Parsers::ShowInterfaceCounter },
        { dimensions: [ :optics ], command: "show transceiver", parser: Parsers::ShowTransceiver },
        { dimensions: [ :bgp ], command: "show ip bgp summary", parser: Parsers::ShowIpBgpSummary },
        { dimensions: [ :ospf ], command: "show ip ospf neighbor", parser: Parsers::ShowIpOspfNeighbor },
        { dimensions: [ :cpu ], command: "show cpu", parser: Parsers::ShowCpu },
        { dimensions: [ :memory ], command: "show memory", parser: Parsers::ShowMemory },
        { dimensions: %i[temperature environment power], command: "show environment", parser: Parsers::ShowEnvironment },
        { dimensions: [ :clock ], command: "show clock", parser: Parsers::ShowClock },
        { dimensions: [ :ntp ], command: "show ntp status", parser: Parsers::ShowNtpStatus },
        { dimensions: [ :device_counters ], command: "show cpu-cntr", parser: Parsers::ShowCpuCntr }
      ])
      COMMANDS = CATALOG.commands
      PARSERS = CATALOG.parsers

      # 在线接口丢弃表不提供错误包或 CRC 测量。
      def counter_metrics = %i[in_errors out_errors crc_errors].freeze
    end
  end
end
