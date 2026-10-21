# ctx_checker 开发指南

本文件适用于本仓库。用户指令优先；更深目录的 AGENTS.md 可细化局部约定。

## 职责与结构

这是网络运行证据与健康检查库，依赖 ctx_parser 和 ctx_driver，独立于 Rails 和数据库。保持“配置适用性 → 命令采集 → 运行解析 → 观测快照 → 策略评估 → 报告”的边界。

- `lib/ctx_checker/collector.rb`：连接器生命周期、发现依赖及命令调度；命令执行委托给 Reader。
- `runtime_parser.rb`、`parser_registry.rb`、各厂商 `profile.rb`：命令选择、共享视图、型号变体及有界发现。
- `parsers/base.rb` 与各厂商 `parsers/`：文本校验、CLI 错误、语法识别与归一化事实。
- `observation.rb`、`observation_merger.rb`、`snapshot.rb`：字段契约、独立来源合并、设备身份与采样时刻。
- `applicability.rb`：从配置证据推导可选功能适用性。
- `policy.rb`、`system_policy.rb`、`checks/`、`evaluator.rb`：显式预期及判定；`report.rb` 汇总结果与覆盖度。
- `COUNTER_CONTRACT.md` 和 `spec/fixtures/**/**_SOURCES.md`：计数语义和设备回显来源，修改相关行为前先读。

## 必须保持的契约

- 输入是命令正文；提示符和命令回显由驱动处理，厂商解析器不猜测任意行是不是提示符。
- 区分 complete/partial/failed/unsupported/not_requested/not_applicable。缺字段、未知语法、截断、未请求及功能不适用不是健康空表。
- 明确 CLI 拒绝与权限错误不能变为成功事实；分页、身份冲突及覆盖不足必须降低完整性。
- 一条共享命令只执行并解析一次，视图分别投影。维度或命令的失败不抹除已有独立证据；合并时拒绝重复来源和 not_requested 片段。
- Collector.collect 的连接器必须恰好 yield 一次；collect_session 借用已有会话，不负责连接和关闭。参数错误在打开连接前报告。
- 发现只能增加请求范围内、有上限的固定查询；不能替换既有命令或解析器，也不能递归生成无限查询。
- 设备身份、维度与命令归属在外部回调前固定。Snapshot 不含连接密码等凭据。
- 批量解析须先校验并快照整批命令与正文，再调用扩展解析器；前一来源的回调不能改变后续来源及其摘要。
- 计数增量要求同设备、同身份、同单位/作用域、递增时间及连续性证据；累计值不能直接证明健康。缺失、重置、回绕和过期应保持未知。
- 路由缺失判定须有相符的 VRF、地址族、进程和接口覆盖证据。局部空表不能证明全设备协议未配置。
- 阈值和拓扑预期由策略声明；解析器提取事实，不猜测通用光功率、温度或资源阈值。
- 报告覆盖度与观测完整性分别呈现；issue/evidence 只保留安全诊断、来源命令、摘要和时刻，不泄露原始回显或异常消息。

## 开发约定

- 使用 `.ruby-version`、gemspec 和锁文件规定的运行时与依赖；当前 Ruby 最低版本和 CI 版本为 4.0.6。修改版本策略时同步检查这三处及 CI。
- 遵循 `.rubocop.yml`：两空格缩进、snake_case 方法和文件、UpperCamelCase 类型、`frozen_string_literal`。代码注释沿用中文，RSpec 示例及 Changelog 沿用英文。
- 厂商 CLI 命令解析器的文件名、类名及目录应继续镜像原命令；必要修复不受限制。命名清理优先针对语义不清的适配器和辅助对象。
- 先查调用者和既有同类实现。抽象应保护业务不变量或隔离协议，不因文件长度或方法数量机械拆分。
- 区分缺失、nil、false、非法和未知。异常只在负责的边界处理；不能用空集合、零值或成功状态掩盖失败。
- 不依赖 Ruby 全局分隔符 `$;`、`$/`、`$,`；拆分、逐行读取和拼接须指定分隔符。处理配置时保留来源原文及换行。
- 在外部回调前固定已校验输入和证据。不要冻结调用方的可变对象；`Data.define` 和外层 `freeze` 不等于成员深度不可变。
- 保留暂存、未暂存和未跟踪改动；不覆盖无关工作，不执行 reset/clean/stash。审查与本地修复本身不代表获得提交、推送或发布授权。

## 验证与交付

在本仓库根目录执行：

```sh
ruby -v
bundle exec rake
bundle exec rake build
```

`rake` 默认包含 RSpec、RuboCop 和全部 examples；examples 使用本地合成数据，不需连接设备。若非交互 shell 误用 macOS 系统 Ruby 2.6，在当前环境使用 `zsh -ic 'bundle exec rake'`；不要为此降级锁文件或修改依赖。

- 缺陷先用最小回归复现，再修复；优先复用已有测试。测试断言实际输出、错误隔离和副作用，不镜像内部实现。
- 性能改动使用 `benchmark/` 中的脚本，记录输入规模、Ruby 版本、代码来源、耗时和分配量；比较前后语义。合成结果不能证明网络吞吐或实机兼容性。
- 公共行为变化记录在 `CHANGELOG.md` 的 Unreleased。当前代码、README 和验证脚本是依据；`docs/architecture-zh.md` 含历史 Motor 宿主记录，不能当成当前 gem 的运行能力。
- 跨仓库联调与锁定依赖测试分别运行并报告。`RUBYLIB` 联调通过不证明已发布依赖兼容；使用 `script/verify_package.rb` 在隔离安装中验证候选包。
- 只有明确要求发布时才执行交付流程，顺序为 ctx_parser → ctx_driver → ctx_runner → ctx_checker；核对精确提交的 CI、制品、校验和及安装读回结果。仓库可见性仅按当前授权调整。

独立安装验证：`ruby script/verify_package.rb pkg/ctx_checker-*.gem`；脚本可接收显式依赖候选包，并按依赖顺序精确激活。修改共享基础类后运行整个厂商测试集，不能只验证一个厂商或维度。离线夹具通过不代表所有型号实机认证。基准入口：`bundle exec ruby -Ilib benchmark/runtime.rb`、`benchmark/report.rb`、`benchmark/protocol_scopes.rb`。

联调当前相邻源码：

```sh
RUBYLIB=../ctx_parser/lib:../ctx_driver/lib bundle exec rake
```

同时保留不带 RUBYLIB 的锁定依赖验证。

配置到报告的完整离线基准：

```sh
RUBYLIB=../ctx_parser/lib:../ctx_driver/lib bundle exec ruby -Ilib benchmark/pipeline.rb
```

该基准使用合成会话；分别报告配置、采集解析与评估阶段的耗时和对象分配，并校验共享查询次数及报告结果。

## 公共业务流程

采集会话约束、共享查询与事实外壳由 `ctx_runner` 提供；VXLAN/Wireless 的批量交付、报告检查点和变更执行也由 Runner 统一维护。领域规则、厂商命令、健康评估及操作租约留在当前模块，不复制公共状态机。

源码联调使用 `CTX_RUNNER_PATH=../ctx_runner bundle exec rake`；普通安装验证不设置该变量。首次发布依赖顺序为 ctx_parser → ctx_driver → ctx_runner → 消费模块。未发布 Runner 时先构建安装候选包，隔离包验证显式传入候选，不能依靠相邻源码路径。
