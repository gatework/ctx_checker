# frozen_string_literal: true

require_relative "../../cisco_ios/parsers/show_ip_ospf_neighbor"

module CtxChecker
  module CiscoNxos
    module Parsers
      # NX-OS 复用已校验的 OSPFv2 行，同时保留分进程总数与明确的 VRF 作用域。
      class ShowIpOspfNeighbors < CiscoIos::Parsers::ShowIpOspfNeighbor
        PLATFORM = :cisco_nxos
      end
    end
  end
end
