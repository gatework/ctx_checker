# frozen_string_literal: true

require "ctx_parser/profile"
require_relative "parsers/show_interfaces"
require_relative "parsers/show_etherchannel_summary"
require_relative "parsers/show_interfaces_transceiver_detail"
require_relative "parsers/show_ip_bgp_summary"
require_relative "parsers/show_ip_ospf_neighbor"
require_relative "parsers/show_processes_cpu"
require_relative "parsers/show_memory_statistics"
require_relative "parsers/show_environment_all"
require_relative "parsers/show_clock_detail"
require_relative "parsers/show_ntp_status"
require_relative "parsers/show_facility_alarm_status"
require_relative "parsers/show_ip_traffic"

module CtxChecker
  module CiscoIos
    # IOS 与 IOS-XE 共用命令契约；型号特有语法通过解析器覆盖。
    class Profile < CtxParser::Profile
      DECLARATIONS = CtxParser::Commands.new([
        { dimensions: %i[interfaces counters], command: "show interfaces", parser: Parsers::ShowInterfaces },
        { dimensions: [ :aggregation ], command: "show etherchannel summary", parser: Parsers::ShowEtherchannelSummary },
        { dimensions: [ :optics ], command: "show interfaces transceiver detail", parser: Parsers::ShowInterfacesTransceiverDetail },
        { dimensions: [ :bgp ], command: "show ip bgp summary", parser: Parsers::ShowIpBgpSummary },
        { dimensions: [ :ospf ], command: "show ip ospf neighbor", parser: Parsers::ShowIpOspfNeighbor },
        { dimensions: [ :cpu ], command: "show processes cpu", parser: Parsers::ShowProcessesCpu },
        { dimensions: [ :memory ], command: "show memory statistics", parser: Parsers::ShowMemoryStatistics },
        { dimensions: %i[temperature environment power], command: "show environment all", parser: Parsers::ShowEnvironmentAll },
        { dimensions: [ :clock ], command: "show clock detail", parser: Parsers::ShowClockDetail },
        { dimensions: [ :ntp ], command: "show ntp status", parser: Parsers::ShowNtpStatus },
        { dimensions: [ :alarms ], command: "show facility-alarm status", parser: Parsers::ShowFacilityAlarmStatus },
        { dimensions: [ :device_counters ], command: "show ip traffic", parser: Parsers::ShowIpTraffic }
      ])
    end
  end
end
