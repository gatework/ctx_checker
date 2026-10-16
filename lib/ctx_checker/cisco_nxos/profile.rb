# frozen_string_literal: true

require "ctx_parser/profile"
require_relative "parsers/show_interface"
require_relative "parsers/show_port_channel_summary"
require_relative "parsers/show_interface_transceiver_details"
require_relative "parsers/show_bgp_ipv4_unicast_summary"
require_relative "parsers/show_system_resources"
require_relative "parsers/show_environment"
require_relative "parsers/show_clock"
require_relative "parsers/show_ntp_peer_status"
require_relative "parsers/show_ip_traffic"
require_relative "parsers/show_ip_ospf_neighbors"

module CtxChecker
  module CiscoNxos
    # NX-OS 命令选择保留完整接口详情，并明确 IPv4 BGP 作用域。
    class Profile < CtxParser::Profile
      CATALOG = CtxParser::CommandCatalog.new([
        { dimensions: %i[interfaces counters], command: "show interface", parser: Parsers::ShowInterface },
        { dimensions: [ :aggregation ], command: "show port-channel summary", parser: Parsers::ShowPortChannelSummary },
        { dimensions: [ :optics ], command: "show interface transceiver details", parser: Parsers::ShowInterfaceTransceiverDetails },
        { dimensions: [ :bgp ], command: "show bgp ipv4 unicast summary", parser: Parsers::ShowBgpIpv4UnicastSummary },
        { dimensions: [ :ospf ], command: "show ip ospf neighbors", parser: Parsers::ShowIpOspfNeighbors },
        { dimensions: %i[cpu memory], command: "show system resources", parser: Parsers::ShowSystemResources },
        { dimensions: %i[temperature environment power], command: "show environment", parser: Parsers::ShowEnvironment },
        { dimensions: [ :clock ], command: "show clock", parser: Parsers::ShowClock },
        { dimensions: [ :ntp ], command: "show ntp peer-status", parser: Parsers::ShowNtpPeerStatus },
        { dimensions: [ :device_counters ], command: "show ip traffic", parser: Parsers::ShowIpTraffic }
      ])
      COMMANDS = CATALOG.commands
      PARSERS = CATALOG.parsers
    end
  end
end
