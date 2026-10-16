# frozen_string_literal: true

require_relative "counters_table"

module CtxChecker
  module H3c
    module Parsers
      # 解析接收错误包数量，避免把正常流量计入错误。
      class DisplayCountersInboundInterface < CtxChecker::Parsers::Base
        include CountersTable

        private

        # 解析 display counters inbound interface，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          parse_counters(text, complete: complete, metric: :in_errors)
        end
      end
    end
  end
end
