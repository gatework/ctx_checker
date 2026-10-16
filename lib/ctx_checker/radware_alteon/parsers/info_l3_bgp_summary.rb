# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # 传统 BGP 表与 FRR BGP 表分别使用已验证的语法。
      class InfoL3BgpSummary < CtxChecker::Parsers::Base
        private

        # 协议明确禁用不代表策略要求的对等体健康。
        def parse_output(text, complete:)
          lines = clean(text).lines.map(&:strip).reject(&:empty?)
          disabled = lines == [ "BGP is disabled." ]
          issues = [ { code: disabled ? :protocol_disabled : :unrecognized_bgp_output } ]
          build_result([], complete: complete, recognized: disabled, issues: issues)
        end
      end
    end
  end
end
