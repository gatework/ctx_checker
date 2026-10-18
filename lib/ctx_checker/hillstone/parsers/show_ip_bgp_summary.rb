# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module Hillstone
    module Parsers
      # BGP 配置为空属于明确证据，但不能证明所有 VRouter 均健康。
      class ShowIpBgpSummary < CtxChecker::Parsers::Base
        private

        # 仅支持已观察到的 StoneOS 格式，不假设使用 Cisco 表格语法。
        def parse_output(text, complete:)
          lines = clean(text).lines("\n").map(&:strip).reject(&:empty?)
          recognized = lines == [ "No IPv4 neighbor is configured" ]
          issues = [ { code: recognized ? :protocol_not_configured : :unrecognized_bgp_output } ]
          build_result([], complete: complete, recognized: recognized, issues: issues)
        end
      end
    end
  end
end
