# 接口计数归一契约

接口计数以 `interface + metric` 为身份，保留 `value`、`unit`、`scope`、`source_command`、
`sampled_at` 和 `discontinuity`。归一化表示同类指标采用一致字段，不表示不同计数可以相加。
`in_errors`、`out_errors`、`in_discards`、`out_discards` 分别表示接收错误、发送错误、接收丢弃和发送丢弃；
CRC 及其他错误子项保留独立指标，可能已包含在错误总数中。

| 字段 | 值 | 含义 |
| --- | --- | --- |
| `unit` | `packets` | 包计数，可应用接口包计数策略 |
| | `bytes` | 字节计数，不转换或当作包数 |
| | `events` | 事件计数，不转换或当作包数 |
| | `unknown` | 命令未证实单位，保留原值，健康判断未知 |
| `scope` | `interface` | 接口整体计数 |
| | `mac` | MAC 层计数 |
| | `cpu` | CPU 接口计数 |
| | `logical` | 逻辑接口计数 |
| | `queue` | 队列计数 |
| | `unknown` | 无法证实范围，健康判断未知 |

`RuntimeParser` 仅在已声明的接口计数命令投影中补齐 `packets/interface` 默认值；解析器的显式
`unit/scope` 优先。厂商适配器必须对单位或范围含糊的字段显式标记 `unknown`，不能把模糊字段静默
交给默认值。`source_command` 始终由命令目录确定，不接受解析器伪造来源。
直接构造的 `Observation` 保留缺失的 `unit/scope` 为 nil，表示语义未知。缺失字段、nil 和显式
`unknown` 均不能用于包计数健康判定；零累计值也不能据此判定正常。

判断包计数增量，需要同设备、同接口指标、单位和范围均相同、采样时间递增，以及连续性标识一致。
任一样本缺少单位或范围时均不计算增量；两个样本同样缺失也不能证明测量语义一致。
`bytes/events/unknown` 单位和 `unknown` 范围均不会使用包阈值，零值也不会据此判定正常。
计数回退、清零或重启后的连续性未知时，不用负差、绝对值或自动溢出修正伪造增量。

同接口同指标的多个命令记录仍属于冲突，不按 `scope` 扩大身份后混合累加。
来源冲突由 `ObservationMerger` 隔离并报告；若需要同时保留两种范围，应先建立明确的独立业务指标契约。
设备级 `device_counters` 使用独立的分类和策略，不继承接口包单位限制。
