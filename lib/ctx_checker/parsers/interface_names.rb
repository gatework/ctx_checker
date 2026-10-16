# frozen_string_literal: true

module CtxChecker
  module Parsers
    # 仅展开已知厂商缩写，保留接口、子接口与成员的身份区别。
    module InterfaceNames
      H3C = {
        "ge" => "GigabitEthernet", "gigabitethernet" => "GigabitEthernet",
        "xge" => "Ten-GigabitEthernet", "ten-gigabitethernet" => "Ten-GigabitEthernet",
        "ten-gige" => "Ten-GigabitEthernet", "fge" => "FortyGigE", "fortygige" => "FortyGigE",
        "hge" => "HundredGigE", "hundredgige" => "HundredGigE",
        "bagg" => "Bridge-Aggregation", "bridge-aggregation" => "Bridge-Aggregation",
        "ragg" => "Route-Aggregation", "route-aggregation" => "Route-Aggregation",
        "vlan" => "Vlan-interface", "vlan-interface" => "Vlan-interface"
      }.freeze
      CISCO = {
        "eth" => "Ethernet", "et" => "Ethernet", "ethernet" => "Ethernet",
        "gi" => "GigabitEthernet", "gig" => "GigabitEthernet", "gigabitethernet" => "GigabitEthernet",
        "fa" => "FastEthernet", "fastethernet" => "FastEthernet",
        "te" => "TenGigabitEthernet", "ten" => "TenGigabitEthernet", "tengigabitethernet" => "TenGigabitEthernet",
        "twe" => "TwentyFiveGigE", "twentyfivegige" => "TwentyFiveGigE", "twentyfivegigabitethernet" => "TwentyFiveGigE",
        "fo" => "FortyGigabitEthernet", "fortygigabitethernet" => "FortyGigabitEthernet",
        "hu" => "HundredGigE", "hundredgige" => "HundredGigE",
        "po" => "Port-channel", "port-channel" => "Port-channel", "vlan" => "Vlan"
      }.freeze
      COMMON = { "lo" => "Loopback", "loopback" => "Loopback", "tu" => "Tunnel", "tunnel" => "Tunnel", "nve" => "Nve" }.freeze

      module_function

      # 展开已知厂商接口缩写，同时保留端口后缀。
      def normalize(name, platform:)
        raise ArgumentError, "Interface name must be text" unless name.is_a?(String) && !name.strip.empty? && !/[\x00-\x1f\x7f]/.match?(name)

        value = name.strip
        return value.downcase if %w[palo_alto paloalto panos hillstone stoneos].include?(platform.to_s)
        if %w[radware_alteon radware alteon].include?(platform.to_s)
          return "port#{Integer(value, 10)}" if /\A[1-9]\d*\z/.match?(value)

          return value.downcase.sub(/\A(port|mgmt|trunk)\s+(\d+)/, '\1\2')
        end

        match = /\A([a-z-]+)\s*(\d.*)\z/i.match(value)
        return value unless match

        aliases = platform.to_s.start_with?("h3c") ? H3C : CISCO
        "#{aliases.fetch(match[1].downcase) { COMMON.fetch(match[1].downcase, match[1]) }}#{match[2]}"
      end

      # 将已知接口名分类为物理口、聚合口、子接口或逻辑口。
      def kind(name)
        case name.to_s
        when /\Aloopback\.?\d/i then :loopback
        when /\A(?:tunnel|nve)\.?\d/i then :tunnel
        when /\.\d+\z/ then :subinterface
        when /\A(?:port-channel|bridge-aggregation|route-aggregation|ae|aggregate|trunk)\d/i then :aggregate
        when /\A(?:vswitchif|bgroup)\d/i then :bridge
        when /\Aredundant\d/i then :redundant
        when /\Avlan(?:-interface)?\d/i then :svi
        when /\A(?:[\w-]*ethernet|[\w-]*gige|mgmt|mgt|ha|cellular|port)\d/i then :physical
        else :unknown
        end
      end
    end
  end
end
