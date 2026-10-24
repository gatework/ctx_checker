# 接口计数的测量语义

## 问题与目标

当前 `Checks::Counters#packet_semantics_reason` 将缺少单位的记录视为包计数，将缺少作用域的记录视为已知范围。`COUNTER_CONTRACT.md` 与现有用例明确保留了这种旧接口语义：零值可以通过，两次缺失字段的记录可以产生包计数增量。这与未知证据不得证明健康及用户拒绝兼容过渡分支的要求冲突。

移除该隐式假设。接口计数阈值必须有 `unit: :packets` 和已知 `scope`；字段缺失、nil 与显式 unknown 统一产生 unknown。原始观测保留缺失事实，不因信息不足而丢弃整份观测。不要把 nil 自动改成 packets/interface。

## 业务边界

`RuntimeParser` 仍只为已经声明语义的厂商接口计数命令补充 packets/interface；厂商解析器的显式未知或非包语义优先。`Observation` 验证和保存事实；`Checks::Counters` 决定事实能否用于当前策略。`DeviceCounters` 使用独立分类和阈值，不要求接口单位。没有新类型、配置项或兼容开关。

当前已知语义与前次缺失/不同语义仍返回 counter_unit_changed 或 counter_scope_changed；当前缺失语义优先返回 counter_unit_unknown 或 counter_scope_unknown。没有可计算的 delta。合法 packet 样本保留身份、连续性、递增采样时间、来源完整性和超限判断。

## 范围与验收

- 修改 Checks::Counters、既有 counter_semantics/evaluator/source_independence/multi_command 用例、计数契约及 Unreleased 记录；加本规格和计划，共九个文件。
- 先用既有语义用例复现零值错误通过和未知单位/作用域增量，再修复；真实 Observation → Snapshot → Evaluator 链不使用判定 mock。
- 包计数测试显式声明 packets/interface，保留原时间、重置、来源隔离及阈值断言。
- 定向、完整 RSpec、显式路径 lint、离线 examples、实际 checkout 默认门禁和安装后业务探针通过。
- 一次独立审查；当前八模块及必要 Wireless 消费者的精确候选重新构建，元数据、文件字节与选定闭包的普通/Bundler 安装分别验证。

## 约束

- Ruby >= 4.0.6；项目 Bundler 与当前依赖政策保持不变。
- lib 方法注释中文，业务字面量英文；不批量翻译测试及文档。
- 不改厂商 CLI 文件/类/目录，不新增厂商支持或推测设备语义。
- 保留所有既有 WIP；未授权提交、推送或发布。
- 本地合成及安装证据不代表所有依赖版本、设备型号、平台或远端 CI。

## 取舍

直接拒绝缺字段的 Observation 会丢弃可报告的未知事实，并使一次字段缺失破坏整个观测；采用统一 unknown 判定。代价是依赖旧隐式包语义的外部调用方必须提供真实单位/作用域，不能通过兼容开关恢复旧判定。
