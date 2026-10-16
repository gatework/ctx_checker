# frozen_string_literal: true

require_relative "../../parsers/base"

module CtxChecker
  module Hillstone
    module Parsers
      # StoneOS 的 OSPF 正文可能为空，但这不能证明邻居或进程覆盖完整。
      class ShowIpOspfNeighbor < CtxChecker::Parsers::Base
        private

        # 在取得真实或文档明确的邻居表前保留未知状态。
        def parse_output(text, complete:)
          source = clean(text)
          issue = source.strip.empty? ? :ospf_neighbor_state_unavailable : :unrecognized_ospf_output
          build_result([], complete: complete, recognized: false, issues: [ { code: issue } ])
        end
      end
    end
  end
end
