# frozen_string_literal: true

require "ctx_parser/profile"
require_relative "parsers/display_interface"
require_relative "parsers/display_link_aggregation_verbose"
require_relative "parsers/display_transceiver_diagnosis"
require_relative "parsers/display_bgp_peer"
require_relative "parsers/display_ospf_peer"

require_relative "parsers/display_cpu_usage"
require_relative "parsers/display_memory"
require_relative "parsers/display_environment"
require_relative "parsers/display_fan"
require_relative "parsers/display_power"
require_relative "parsers/display_clock"
require_relative "parsers/display_ntp_service_status"
require_relative "parsers/display_alarm_active"
require_relative "parsers/display_counters_inbound_interface"
require_relative "parsers/display_counters_outbound_interface"

module CtxChecker
  module H3c
    # 声明 Comware 只读查询；BGP 明确限定为公网 IPv4 单播。
    class Profile < CtxParser::Profile
      DECLARATIONS = CtxParser::Commands.new([
        { dimensions: %i[interfaces counters], command: "display interface", parser: Parsers::DisplayInterface },
        { dimensions: [ :counters ], command: "display counters inbound interface", parser: Parsers::DisplayCountersInboundInterface },
        { dimensions: [ :counters ], command: "display counters outbound interface", parser: Parsers::DisplayCountersOutboundInterface },
        { dimensions: [ :aggregation ], command: "display link-aggregation verbose", parser: Parsers::DisplayLinkAggregationVerbose },
        { dimensions: [ :optics ], command: "display transceiver diagnosis interface", parser: Parsers::DisplayTransceiverDiagnosis },
        { dimensions: [ :bgp ], command: "display bgp peer ipv4", parser: Parsers::DisplayBgpPeer },
        { dimensions: [ :ospf ], command: "display ospf peer", parser: Parsers::DisplayOspfPeer },
        { dimensions: [ :cpu ], command: "display cpu-usage", parser: Parsers::DisplayCpuUsage },
        { dimensions: [ :memory ], command: "display memory", parser: Parsers::DisplayMemory },
        { dimensions: [ :temperature ], command: "display environment", parser: Parsers::DisplayEnvironment },
        { dimensions: [ :environment ], command: "display fan", parser: Parsers::DisplayFan },
        { dimensions: [ :power ], command: "display power", parser: Parsers::DisplayPower },
        { dimensions: [ :clock ], command: "display clock", parser: Parsers::DisplayClock },
        { dimensions: [ :ntp ], command: "display ntp-service status", parser: Parsers::DisplayNtpServiceStatus },
        { dimensions: [ :alarms ], command: "display alarm active", parser: Parsers::DisplayAlarmActive }
      ], multi_command: true)
      COMMANDS = DECLARATIONS.by_dimension
      PARSERS = DECLARATIONS.parsers

      # 每个已观察接口都必须保留入站与出站两个方向的证据状态。
      def counter_metrics = %i[in_errors out_errors].freeze
    end
  end
end
