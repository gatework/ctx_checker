# frozen_string_literal: true

require "ctx_parser/profile"
require_relative "parsers/show_interface_all"
require_relative "parsers/show_counter_interface_all"
require_relative "parsers/show_lacp_aggregate_ethernet"
require_relative "parsers/show_transceiver_all"
require_relative "parsers/show_routing_protocol_bgp_peer"
require_relative "parsers/show_routing_protocol_ospf_neighbor"
require_relative "parsers/show_system_resources"
require_relative "parsers/show_system_environmentals"
require_relative "parsers/show_clock"
require_relative "parsers/show_ntp"
require_relative "parsers/show_system_state_alarms"
require_relative "parsers/show_counter_global"

module CtxChecker
  module PaloAlto
    # 声明传统路由引擎查询；高级路由格式需要独立平台策略。
    class Profile < CtxParser::Profile
      CATALOG = CtxParser::CommandCatalog.new([
        { dimensions: [ :interfaces ], command: "show interface all", parser: Parsers::ShowInterfaceAll },
        { dimensions: [ :counters ], command: "show counter interface all", parser: Parsers::ShowCounterInterfaceAll },
        { dimensions: [ :aggregation ], command: "show lacp aggregate-ethernet all", parser: Parsers::ShowLacpAggregateEthernet },
        { dimensions: [ :optics ], command: "show transceiver all", parser: Parsers::ShowTransceiverAll },
        { dimensions: [ :bgp ], command: "show routing protocol bgp peer", parser: Parsers::ShowRoutingProtocolBgpPeer },
        { dimensions: [ :ospf ], command: "show routing protocol ospf neighbor", parser: Parsers::ShowRoutingProtocolOspfNeighbor },
        { dimensions: %i[cpu memory], command: "show system resources", parser: Parsers::ShowSystemResources },
        { dimensions: %i[temperature environment power], command: "show system environmentals", parser: Parsers::ShowSystemEnvironmentals },
        { dimensions: [ :clock ], command: "show clock", parser: Parsers::ShowClock },
        { dimensions: [ :ntp ], command: "show ntp", parser: Parsers::ShowNtp },
        { dimensions: [ :alarms ], command: "show system state | match alarm", parser: Parsers::ShowSystemStateAlarms },
        { dimensions: [ :device_counters ], command: "show counter global", parser: Parsers::ShowCounterGlobal }
      ])
      COMMANDS = CATALOG.commands
      PARSERS = CATALOG.parsers
    end
  end
end
