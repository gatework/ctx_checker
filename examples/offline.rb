# frozen_string_literal: true

require "ctx_checker"

# 使用合成的 IOS 命令回显，本例不连接设备。
output = "GigabitEthernet1/0/1 is up, line protocol is up\n"
parser = CtxChecker::RuntimeParser.new(platform: :cisco_ios)
observation = parser.parse(:interfaces, output, complete: true)
snapshot = CtxChecker::Snapshot.new(
  target: { host: "192.0.2.10", platform: parser.platform },
  observed_at: Time.utc(2026, 1, 1),
  observations: { interfaces: observation }
)
policy = CtxChecker::Policy.new(required_interfaces: [ "GigabitEthernet1/0/1" ])
report = CtxChecker::Evaluator.new(policy: policy).call(snapshot)
puts report.to_text
# 未请求的维度保持 not_requested，本例不代表整机检查。
