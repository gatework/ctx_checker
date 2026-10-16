# frozen_string_literal: true

require_relative "counters_table"

module CtxChecker
  module H3c
    module Parsers
      # 解析发送错误包数量；CRC 与丢弃量需要独立证据。
      class DisplayCountersOutboundInterface < CtxChecker::Parsers::Base
        include CountersTable

        private

        # 解析 display counters outbound interface，保留不完整或不支持的证据。
        def parse_output(text, complete:)
          parse_counters(text, complete: complete, metric: :out_errors)
        end
      end
    end
  end
end
