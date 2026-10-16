# frozen_string_literal: true

require_relative "../../cisco_ios/parsers/show_clock_detail"

module CtxChecker
  module CiscoNxos
    module Parsers
      # NX-OS 使用相同的时钟正文，不含 IOS 的 detail 关键字。
      class ShowClock < CtxChecker::CiscoIos::Parsers::ShowClockDetail
      end
    end
  end
end
