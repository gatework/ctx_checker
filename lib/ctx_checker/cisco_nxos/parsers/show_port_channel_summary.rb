# frozen_string_literal: true

require_relative "../../cisco_ios/parsers/show_etherchannel_summary"

module CtxChecker
  module CiscoNxos
    module Parsers
      # NX-OS 使用相同的聚合组与成员标志，另增加接口类型列。
      class ShowPortChannelSummary < CiscoIos::Parsers::ShowEtherchannelSummary
        PLATFORM = :cisco_nxos

        private

        # 部分终端会将下一表格行附加在占满终端宽度的分隔线后。
        def parse_output(text, complete:)
          super(clean(text).gsub(/^([ \t]*-{3,})(?=Group\s+Port-|\d+\s+(?:Po|port-channel)\d+\()/i, "\\1\n"), complete: complete)
        end
      end
    end
  end
end
