# frozen_string_literal: true

require "bundler/setup"
require "rspec/core"
require "ctx_checker"

# 通用借用会话只依赖 Driver 回执协议，不绑定可选连接器的结果实现。
module CommandReceipts
  Receipt = Data.define(:output, :steps, :body) do
    def success? = true
    def value! = body
  end

  # 原始证据与清理后正文分别提供，空步骤用于保留非法成功回归。
  def command_receipt(body, output: body, steps: [ Object.new.freeze ])
    Receipt.new(output: output, steps: steps, body: body)
  end
end

RSpec.configure do |config|
  config.include CommandReceipts
  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.mock_with(:rspec) { |mocks| mocks.verify_partial_doubles = true }
  config.order = :random
  Kernel.srand config.seed
end
