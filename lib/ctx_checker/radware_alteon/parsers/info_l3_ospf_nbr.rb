# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module RadwareAlteon
    module Parsers
      # OSPF 正文为空不能推断邻居或进程覆盖完整。
      class InfoL3OspfNbr < CtxChecker::Parsers::Base
        private

        # 在验证活跃 Alteon 邻居表前，保留明确禁用状态。
        def parse_output(text, complete:)
          lines = clean(text).lines("\n").map(&:strip).reject(&:empty?)
          disabled = lines == [ "OSPF is disabled." ]
          issues = [ { code: disabled ? :protocol_disabled : :unrecognized_ospf_output } ]
          build_result([], complete: complete, recognized: disabled, issues: issues)
        end
      end
    end
  end
end
