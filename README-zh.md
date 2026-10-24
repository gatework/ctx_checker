# ctx_checker

[English](README.md) | [源码](https://github.com/gatework/ctx_checker) | [变更记录](CHANGELOG.md)

面向异构网络设备的运行时健康检查。厂商解析器归一化观测指标，策略基于事实判定，缺失证据不会被当作健康。

## 能力

- 接口、归一化 error/drop 计数、聚合成员、光模块、BGP 和 OSPF。
- CPU、内存、温度、环境、电源、时钟、NTP、活动告警及设备计数。
- H3C、Cisco IOS/IOS-XE、Cisco NX-OS、Palo Alto、Hillstone 和 Radware Alteon 策略；各平台覆盖范围不同。
- 命令执行及解析独立隔离、显式适用性判断，以及可选的前次采样比较。

## 安装

要求 **Ruby 4.0.6 或更新版本**。在应用的 `Gemfile` 中添加：

```ruby
gem "ctx_checker"
```

然后执行 `bundle install`；也可直接执行 `gem install ctx_checker`。Ruby 加载入口为 `ctx_checker`，公开命名空间为 `CtxChecker`；gem 包名与 Ruby 命名空间分别维护。

模块运行依赖：[`ctx_parser`](https://github.com/gatework/ctx_parser), [`ctx_driver`](https://github.com/gatework/ctx_driver), [`ctx_runner`](https://github.com/gatework/ctx_runner)。gemspec 不限制依赖版本；应用应提交经过验证的 `Gemfile.lock`，保持部署可复现。使用本库不需要启动 Rails 或配置兄弟模块的本地路径。

发布产物和校验值见 [GitHub Releases](https://github.com/gatework/ctx_checker/releases)，已发布版本以 [RubyGems](https://rubygems.org/gems/ctx_checker) 为准。

## 离线示例

在开发检出目录安装依赖后执行：

```sh
bundle exec ruby examples/offline.rb
```

示例使用合成数据，不访问网络。完整代码见 [examples/offline.rb](examples/offline.rb)：

```ruby
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
```

## 公开契约与限制

`RuntimeParser.new(platform:, model: nil, software_version: nil)` 提供 `parse`、`parse_many`、`parse_outputs`。以观察结果构建 `Snapshot`，再用 `Evaluator.new(policy: Policy.new).call(snapshot, previous: nil)` 判定；报告提供 `to_text`、`to_h`、`summary` 及覆盖率。

观察完整性 `complete/partial/failed/unsupported/not_requested/not_applicable` 与业务结论 `pass/fail/unknown/not_applicable` 分开。空回显不能独自证明健康或功能未配置。可信配置可证明可选 BGP、OSPF 或聚合检查不适用，必检策略仍优先。

快照字符串、命令证据和记录中的采样时间必须使用有效日期及明确的 `Z` 或 UTC 偏移；快照也接受 `Time` 对象。聚合容量仅计入有完整来源证据的成员，不完整成员不能证明容量充足，也不能证明容量不足。

error、CRC、discard 保持独立，不相加；单次累计值不能当作当前错误速率。增量要求身份一致、时间递增及可靠连续性证据。光功率需要设备或策略阈值；已有格式支持不代表所有型号/版本都已验证。

`Collector#collect` 接收负责会话生命周期的 connector；`collect_session` 借用已有会话。本 gem 不包含 Rails、库存数据库、调度或凭据。指标语义见[计数契约](COUNTER_CONTRACT.md)。

采集会在调用时钟或连接器前固定已校验的目标与所选维度。生命周期连接器的 `open` 必须恰好提供一次会话；未提供或提供两次均抛出 `ArgumentError`，第二次回调不会重复执行查询。合并命令结果时不接受 `not_requested` 观察片段。

详细厂商语义、历史验证记录和 Motor 专用集成说明保留在[架构参考](docs/architecture-zh.md)。其中宿主集成代码需要 Motor，不属于独立 gem API。适配层位于 [Motor 仓库](https://github.com/gatework/motor/tree/main/backend/lib) 的 `backend/lib/baseline`、`backend/lib/vxlan` 和 `backend/lib/wireless`。

生命周期 connector 是宿主适配器，提供 `open { |session| }`，VXLAN 和 Wireless 还要求 `platform`；原生 `Net::Connector::Base` 实例并不提供这一宿主生命周期协议。已连接的原生会话可传入 `CtxDriver::Reader` 或 `CtxChecker::Collector#collect_session`，不会隐式连接或重试。

## 领域术语

`Observation` 表示某维度的采集证据，`Finding` 表示健康判定。`Policy#required_dimension?`、`SystemPolicy#required_dimension?` 查询必需观测维度。接口与光学测量仍按其完整身份匹配要求。计数器阈值比较经过连续性验证的采样区间内增量，区间以秒计；阈值不是累计总量或每秒速率。

整数 OSPF 进程 ID 在策略、观测记录和覆盖作用域中统一转换成字符串，再检查身份重复。明确配置温度阈值时必须有数值读数，只有 `ok` 状态不能满足阈值策略。每个解析结果最多保留 128 条诊断样本，额外的 `diagnostics_truncated` 摘要记录省略数量；截断不能证明证据完整。

## 开发与测试

原生 net-connector 0.13 集成测试要求 ctx_driver 0.2.2 或更新版本。通用借用会话夹具直接实现回执协议，不依赖连接器的结果类。`bundle exec ruby examples/connector.rb` 通过本地 PTY 贯通五个 gem，验证共享命令采集、原始证据、解析观测、健康判断和命令拒绝后不隐式重连；使用合成回显，无须网络设备或凭据。

共享类按实际职责命名，平台信息放在命名空间中。直接对应设备命令的解析器保留文件名和类名。

CLI 解析显式指定字段与行分隔符，按语义使用 `split(" ")`、`each_line("\n")` 和 `join("\n")`。宿主应用修改 Ruby 全局分隔符时，设备事实和来源证据必须保持一致。

```sh
bundle install
bundle exec rake
bundle exec ruby examples/offline.rb
bundle exec rake build
```

`bundle exec rake` 执行 RSpec、RuboCop、离线及本地 PTY 示例。测试放在 `spec/`，沿用项目 RSpec 约定；样例采用合成或脱敏证据。新增解析格式时补充成功、不完整、不支持及非法输入回归。离线测试不代表所有设备版本均通过实机验证。

运行 `ruby script/verify_package.rb /path/to/ctx_checker.gem`，验证使用已发布依赖的隔离安装。联动开发时可追加明确构建的依赖包路径，例如 `/path/to/ctx_parser.gem`，先安装并精确激活这些候选版本，不兼容的候选会使验证失败；候选包验证通过不代表注册表中的依赖已兼容。`bundle exec ruby -Ilib benchmark/runtime.rb` 用合成输入测量本地命令查找和诊断开销。`bundle exec ruby benchmark/report.rb` 测量 64、256、512 条失败查询的报告构建开销，不含网络和解析时间。

使用声明的最低 Ruby 版本检查兼容性。方法用途统一使用简明中文注释；复杂实现还需说明业务规则、实现思路及关键分支。保持公开返回值与错误契约。真实回显和凭据不可进入示例、fixture、日志或发布包。

## 发布

本目录可独立维护为 [ctx_checker](https://github.com/gatework/ctx_checker) 仓库。更新 `VERSION` 和 `CHANGELOG.md`，运行上述验证与构建命令，检查包内文件，再创建 `vVERSION` 标签。

CI 在 Linux、macOS 上执行测试、lint、示例、构建和隔离安装。`main` 的 CI 通过后推送 `vVERSION` 标签，工作流将已验证的 Linux 产物发布到 RubyGems 和 GitHub Release，附带 `SHA256SUMS` 并回读下载字节。GitHub `release` environment 可配置 `RUBYGEMS_API_KEY` secret；未配置时使用 RubyGems Trusted Publishing，绑定本仓库、`release.yml` 和 `release` environment。失败时重跑失败的发布 job，以复用原 CI 产物；同版本已存在时必须校验字节一致。详见[发布说明](docs/release.md)。

先发布依赖模块。标签、构建成功或工作流文件都不等于已经发布，需单独确认 RubyGems 的实际结果。版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。
