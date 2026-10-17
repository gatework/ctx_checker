> 本文保留模块从 Motor 提取前的领域设计、覆盖范围、限制与验证记录，供兼容迁移和故障分析使用。
> 当前独立 gem 的安装、依赖、开发与发布入口以 [README-zh.md](../README-zh.md) 为准。
> 涉及 `Motor::*`、`Sync`、`Baseline::Check`、数据库、Rails、Rake 运维任务及私有实机证据的内容均属于 Motor 宿主集成，不随 gem 提供；历史验证记录不代表当前用户设备已经验证。

# CtxChecker 运行态健康检查

## 设计契约

本模块分析设备运行态。支持 H3C/Comware、Cisco IOS/IOS-XE、Cisco NX-OS、Palo Alto PAN-OS、Hillstone/StoneOS、Radware Alteon。
复用 CtxParser 的解析与命令目录；复用 net-connector 的连接、分页处理和命令执行。
不依赖 Netstack、VXLAN、Wireless 或 Active Record。基线配置合规仍由 Baseline 负责。

```text
Profile (厂商 / 型号命令目录)
             |
net-connector session -> Collector / CtxDriver::Reader -> 逐命令 Parser
                                         |
                                  Observation -> Snapshot
                                                    |
                                      Policy -> Evaluator -> Report
```

### 文件组织

* `lib/ctx_checker/{observation,snapshot,policy,finding,report}.rb`：不可变领域对象和公共契约。
* `lib/ctx_checker/{system_fields,system_policy,observation_merger}.rb`：系统指标字段、运行阈值及多命令证据组合。
* `lib/ctx_checker/{evaluator,collector,runtime_parser,parser_registry}.rb`：判定组合、采集和离线入口。
* `lib/ctx_checker/checks/*.rb`：按指标组织的厂商无关检查。
* `lib/ctx_checker/parsers/{base,interface_names,scoped_result}.rb`：文本边界、完整性、接口名称及协议表范围证明。
* `lib/ctx_checker/{h3c,cisco_ios,cisco_nxos,palo_alto,hillstone,radware_alteon}/profile.rb`：只读查询目录及厂商发现策略。
* `lib/ctx_checker/<platform>/parsers/<command>.rb`：一个命令一个解析器；一份回显包含多个指标时返回 Results。

不创建每厂商一个巨型解析模板。共享同一语法才共享解析机制；健康规则集中在 checks。
型号变体通过 Profile 策略或 MODEL_PARSERS 显式扩展，不按未知型号猜测命令。

### 统一记录

所有记录使用 symbol 键，未知字段保持 nil，不以 0、UP 或空数组冒充已知事实。

| 维度 | 记录字段 |
| --- | --- |
| interfaces | name, kind, admin_status, oper_status, protocol_status, protocol_applicable, parent |
| counters | interface, metric (in_errors/out_errors/in_discards/out_discards/crc_errors 等), value, unit, scope, discontinuity, sampled_at, source_command |
| aggregation | group, member, member_status (active/standby/down/suspended/unselected/unknown), oper_status |
| optics | interface, lane, metric (tx_power/rx_power), value, unit (dbm), low_alarm, low_warning, high_warning, high_alarm, alarm, present, dom_supported |
| bgp | vrf, afi_safi, peer, state, received_prefixes, remote_as |
| ospf | vrf, process_id, area, interface, router_id, neighbor_address, state, network_type, local_role, neighbor_role |
| cpu | component, scope, window_seconds, utilization, interrupt_utilization |
| memory | component, scope, utilization, total_bytes, used_bytes, free_bytes, available_bytes, basis, status |
| temperature | component, value, low_alarm, low_warning, high_warning, high_alarm, high_comparison, status |
| environment | component, kind (fan/voltage/module/clock/overall/unknown), status |
| power | component, kind (power_supply/power_rail/unknown), status, present, watts, capacity_watts |
| clock | component, time (ISO8601，明确 UTC offset), source, synchronized |
| ntp | component, synchronized, stratum, reference, peer, offset_ms, leap, last_sync_status, last_sync_at |
| alarms | component, alarm_id, severity (info/warning/critical/unknown), active, count |
| device_counters | component, metric (厂商命名指标), category (error/discard/policy/informational/unknown), value, discontinuity, sampled_at |

接口 kind 为 physical/aggregate/bridge/redundant/svi/loopback/tunnel/subinterface/unknown；admin_status 为 up/down/unknown；
oper_status 和 protocol_status 为 up/down/unknown。协议状态使用规范化小写 symbol。
接口缩写在平台内部归一，保留可对齐的成员、计数器和光模块身份。
BGP 身份包含 VRF 和 AF，OSPF 身份包含 VRF、进程、接口和 router-id。
系统指标按 component/plane/pool 区分；CPU 身份还包含采样窗口。CPU 与内存 utilization 为百分比，
温度为摄氏度，功率为瓦，NTP offset 为毫秒。硬件状态为 ok/warning/critical/failed/absent/unknown。
内存 `used_bytes` 随 basis 表示有效占用，`free_bytes` 是原始物理空闲量，`available_bytes` 包含可回收缓存。
`used_total`、`available`、`used_minus_cache` 可用于占用率判定；仅有包含缓存的 `used_including_cache` 或未知基准时保持 unknown。
温度 `high_comparison: :gte/:gt` 区分达到/超过阈值；厂商边界未知且读数恰等上限时保留 unknown。

### 公共入口

* `RuntimeParser.new(platform:, model: nil, software_version: nil).parse(name, text, complete: false)` 返回 Observation。
* 同一命令多维度使用 `parse_many(names, text, complete: false)`，只解析一次。
* 一个维度需要多个命令时使用 `parse_outputs(name, { command => text }, complete: false)`，分别解析后组合。
* `parse(..., command:)` 可查看多来源维度的一份证据，该维度保持 partial；不会将多种回显拼接成一个模板。
* `Snapshot.new(target:, observed_at:, observations:, issues: [])`；target 仅允许 host/platform/model/software_version/id。
* `Evaluator.new(policy: Policy.new).call(snapshot, previous: nil)` 返回 Report。
* `Collector.new.collect(target:, connector:, dimensions:)` 通过 connector.open 管理会话。
* `Collector.new.collect_session(target:, session:, dimensions:)` 借用会话，不关闭它。

### 有界发现与查询展开

需要逐端口查询的平台可实现 `Profile#discovery_dimensions(requested)` 和
`Profile#expand(observations, dimensions:)`。依赖必须是目录已声明的固定查询维度；
展开返回新 Profile，只能增加请求维度的新命令，不能替换既有命令、解析器或为已执行命令添加新视图。
一次展开最多增加 512 条唯一命令。厂商 Profile 还负责验证端口格式、数值范围与端口数量。

**Profile 负责确认具体来源完整。** 合并 Observation 为 partial 不代表每一份来源都失败；
例如逻辑接口查询失败时，完整的物理端口来源仍可用于端口计数发现。Profile 必须同时检查所需
command evidence 的状态和所选记录的 `source_complete`，不能仅从部分记录猜测剩余端口。
RuntimeParser 负责类型及有界目录校验，不以一个依赖失败阻断其他独立依赖。

Collector 先采集依赖，再执行展开后的独立查询。未请求的依赖不参与健康判定；依赖不可用时，
待展开维度保留原查询的问题及证据，其他检查继续。断链原因跨阶段保留，不自动重连或重放。
离线使用 `parser.expand({ interfaces: observation }, dimensions: [:counters])` 获得新 RuntimeParser，
随后调用其 `parse_outputs`；原实例保持不变，未声明的查询正文始终拒绝解析。

### 判定不变量

1. Observation 状态为 complete/partial/failed/unsupported/not_requested/not_applicable，与业务 pass/fail/unknown/not_applicable 分离。
2. 未请求、执行失败、解析失败、显式空表分别记录；空集合永不自然通过。部分证据中的明确故障仍保留。
3. admin-down 默认不适用；声明必须运行的接口在完整采集下缺失或 DOWN 为故障。
4. 聚合 standby 正常；active/down/suspended/unselected 分别判断。父口 UP 不能掩盖成员故障，最低成员数来自策略。
5. CRC、错误、丢弃不相加。单样本非零累计计数仅提示历史异常；增量要求相同设备、时间递增及计数连续。
6. 光功率依据模块阈值或显式策略；缺阈值、无 DOM、N/A 不伪造正常。逐 lane 判断，admin-down 低光结合接口上下文。
7. BGP Established 且接收 0 前缀可以通过；OSPF Full 正常，2-Way 仅有适当网络类型和 DR Other 证据时通过。
8. 一台设备一个会话逐命令执行，共享命令只执行一次。断连停止后续命令，不自动重连或重放。
9. 报告只保存结构化指标、问题码、命令摘要和 SHA256/字节数，不保存凭据、原始输出或原始异常消息。
10. CPU 不累加总占用和 interrupt 子集，不跨处理平面或时间窗口求平均。内存不把可回收缓存直接当故障。
11. 温度使用设备或精确传感器策略阈值；不存在跨型号通用温度阈值。缺席且仍有读数、容量矛盾等证据单独报告。
12. NTP peer 可达不代表系统同步；只有 component 为 system 的同步证据用于系统判定。本地 LOCAL 时源、无效 stratum/leap 不通过上游同步检查。
13. active alarms 与历史日志分开；只有明确无活动报警的证据才可通过。策略拒绝和信息计数默认展示，声明具体增量限制后才判定。

物理口、聚合口的已知运行 UP 可以判定链路正常，不要求每个厂商都输出独立的 line-protocol 字段；
已知 protocol DOWN 仍保留故障；只有明确 `protocol_applicable: false` 的二层接口可免于 IP 协议检查，
真实链路 DOWN 仍报告。逻辑口所需状态不足时保持 unknown。
Report 的 `coverage` 是已作出 pass/fail 判断的检查项比例；各维度采集状态同时保存在 `observations` 中。

### 验证与适配边界

测试覆盖正常、异常、缺字段、截断、CLI 错误、重复身份、未知语法、空表、会话中断和关闭失败。
H3C、NX-OS、Hillstone、Radware Alteon 已有指定型号的实机回显回归，其余使用注明来源的最小样例；离线通过不代表所有型号实机认证。
命令不支持或格式不认识时保留 unsupported/partial，不回退成健康结果。
纯 Ruby 检查库不依赖数据库。Motor 的接口错误/丢弃历史另由
`Motor::Devices::InterfaceCounterSync` 写入 `device_interface_counters`，部署该持久化入口需要迁移；
见[历史表与采集说明](https://github.com/gatework/motor/blob/main/backend/docs/DEVICE_INTERFACE_COUNTERS.md)和[统一计数契约](../COUNTER_CONTRACT.md)。

## 使用

### 离线分析

输入必须是命令正文。`net-connector` 的 `result.value!` 已去除命令回显及终端提示符；
保存的原始会话文本应由宿主按已知命令和提示符移除装饰，不让解析器猜测任意一行是不是提示符。
`complete: true` 是调用方对这一份回显完整性的声明，不代表全设备、全部 VRF 或全部地址族已经覆盖。

```ruby
require "ctx_checker"

parser = CtxChecker::RuntimeParser.new(platform: :cisco_ios, model: "C9300")
observations = parser.parse_many(
  %i[interfaces counters], File.read("show_interfaces.txt"), complete: true
)
snapshot = CtxChecker::Snapshot.new(
  target: { host: "192.0.2.10", platform: parser.platform, model: "C9300" },
  observed_at: Time.now.utc,
  observations: observations
)
policy = CtxChecker::Policy.new(required_interfaces: [ "GigabitEthernet1/0/1" ])
report = CtxChecker::Evaluator.new(policy: policy).call(snapshot)
puts report.to_text
# report.to_h：完整结构化证据与结论；report.summary：紧凑结果。
```

策略使用规范化接口全名；可通过
`CtxChecker::Parsers::InterfaceNames.normalize("Gi1/0/1", platform: :cisco_ios)` 转换缩写。
`parser.profile.commands` 提供当前平台的维度到命令映射，不需要调用方硬编码命令表。
单命令映射仍为 String，多命令映射为冻结 Array；`parser.profile.commands_for(:counters)` 始终返回命令数组。

H3C 两方向计数按独立脚本采集，CRC/丢弃明细来自原接口查询；离线使用如下方式：

```ruby
parser = CtxChecker::RuntimeParser.new(platform: :h3c)
counters = parser.parse_outputs(:counters, {
  "display interface" => File.read("interfaces.txt"),
  "display counters inbound interface" => File.read("inbound.txt"),
  "display counters outbound interface" => File.read("outbound.txt")
}, complete: true)
```

缺少命令、接口或某个方向的指标会保留诊断，未知值为 nil。表格的 Total/Broadcast/Multicast 是流量量值，
不会作为错误、CRC 或丢弃计数；`Err` 仅映射对应方向的错误。H3C 的接口摘要不求和冒充设备全局计数，
目前 H3C `device_counters` 为 unsupported，且不执行 packet-drop 查询。

### Motor 与 net-connector

Motor 中复用现有凭据及连接边界：

```ruby
connector = Motor::Devices::Connector.new(device)
snapshot = CtxChecker::Collector.new.collect(
  target: { id: device.id, host: device.ip.to_s, platform: connector.platform.to_s, model: device.model },
  connector: connector,
  dimensions: %i[interfaces counters aggregation optics bgp ospf cpu memory temperature environment power clock ntp alarms device_counters]
)
report = CtxChecker::Evaluator.new.call(snapshot)
```

独立 Ruby 程序可以由 `Net::Connector.open(platform, **settings)` 建立连接，在块中调用
`collect_session(target:, session:, dimensions:)`。连接参数由宿主提供，不放入 Snapshot、Policy 或 Report。
采集器仅调用固定目录中的查询，不配置设备；跨设备并发由宿主控制，同设备命令始终顺序执行。
省略 dimensions 时默认请求上述全部 15 维度；不支持的维度直接记录 unsupported，不执行猜测命令。
打开连接前验证目标身份、维度及 Profile/Parser 注册；调用参数和目录配置错误仍抛出。
进入采集后，每条查询分别处理执行、响应读取、解析、视图投影和字段校验中的 `StandardError`，
只将该命令或该视图记录为 failed，保留前序事实，并在会话仍可用时继续后续独立查询。
`Interrupt`、`SystemExit` 等取消信号继续向上抛出。已知连接生命周期异常转换为结构化采集失败。

### 逐脚本隔离与版本差异

公共 [`CtxDriver::Reader`](https://github.com/gatework/ctx_driver) 对支持此选项的 net-connector 会话显式传入
`send_commands([command], preserve_session_on_rejection: true)`。这个选项只允许单条命令；
设备明确拒绝命令且完整回到原来的固定提示符，或 Alteon 查询明确声明的目标菜单时，连接器返回失败 Result，并保留同步的会话以执行下一条查询。
失败回显不产生健康事实；报告中保留 `device_error` 和执行阶段。连接器默认行为不变，普通调用仍在拒绝后关闭。
未提供该显式关键字的旧 adapter 继续使用原接口；如果它在失败后关闭了会话，剩余查询记录 skipped。

超时、EOF、输出上限、未声明的提示符改变或连接器钩子/日志错误仍关闭会话；采集器保留已经完成的结果，
并将其余脚本标记未执行，不自动重连、重发或尝试未声明的兼容命令。适配新版本时可通过 Profile/Registry
注册经验证的命令和独立解析器，无需改变检查规则。

共享命令只执行、解析一次，再分别构建各维度 Observation。某个视图缺失或字段不合法，不影响该命令的其他有效视图。
H3C 入方向、出方向和接口详情保持三个独立来源；完整来源的记录可以独立得出 pass，
缺失的方向仍是 unknown，整个检查报告保持不完整。来源为 partial 的记录不会升级为健康。
每条记录的 `source_complete`、每份 evidence 的 `status` 由 RuntimeParser 根据原始 Result 生成。

`report.commands`、`report.to_h[:commands]` 和 `report.summary[:commands]` 按命令列出状态、维度及诊断；
状态包括 complete、partial、failed、unsupported 和 skipped。文本报告也会列出未完成的命令。
诊断只保存 `code`、`stage`、安全的 `error_type` 等结构化字段，阶段包括 execute、response、parse、project、validate、session；
不保存异常消息、堆栈或原始输出。采集失败与设备健康故障分别表达，执行失败不会让整个设备被误判为健康。

### 检查策略

```ruby
policy = CtxChecker::Policy.new(
  required_interfaces: [ "Ethernet1/1", "Port-channel10" ],
  required_members: { "Port-channel10" => [ "Ethernet1/1", "Ethernet1/2" ] },
  minimum_active_members: { "Port-channel10" => 2 },
  expected_bgp: [ { vrf: "default", afi_safi: "ipv4_unicast", peer: "192.0.2.2" } ],
  expected_ospf: [ { vrf: "default", process_id: "1", interface: "Ethernet1/1", router_id: "192.0.2.3" } ],
  counter_limits: { crc_errors: 0, in_errors: 5 },
  device_counter_limits: { "flow_policy_deny" => 20 },
  required_dimensions: %i[cpu memory ntp],
  required_components: { power: [ "power supply 1", "power supply 2" ] },
  resource_thresholds: { cpu: { warning: 80, critical: 95 }, memory: { warning: 85, critical: 95 } },
  temperature_thresholds: { "slot 1/sensor 1" => { high_warning: 70, high_alarm: 85, high_comparison: :gte } },
  max_clock_skew_seconds: 300,
  max_ntp_offset_ms: 100,
  optical_thresholds: [
    { interface: "Ethernet1/1", lane: 0, metric: :rx_power, low_alarm: -10, high_alarm: 2 }
  ]
)
```

光阈值按接口、lane、指标精确匹配；省略 lane 表示 nil，不是通配。策略替换该指标的整个阈值集，
必须含完整 alarm 或 warning 上下限，且数值顺序正确；设备显式告警仍优先保留。

预期邻居必须包含作用域；不能用另一个 VRF 的同 IP 邻居替代。`Observation#covered_scopes` 独立于实体记录保存完整枚举的范围：
BGP 为 `vrf/afi_safi`，OSPF 为 `vrf/process_id`，可进一步限定 `interface`。
H3C IPv4 BGP、Cisco IOS/NX-OS BGP，以及明确给出进程的 Cisco OSPF 表会保留此证明，完整空表也不丢失范围。
该范围内必需邻居缺失为 fail；没有范围证明的空表、截断、未知 VRF/地址族仍为 unknown。
兄弟命令失败使合并观察 partial，但不会抹掉成功命令已确认的范围；整体报告仍不完整。
其他厂商没有明确范围证据时继续保守判断，不根据厂商名称猜测全设备覆盖。
空表本身不产生 pass，也不伪造一条邻居记录。范围信息只在非空时加入序列化，旧快照和计数指纹保持原形状。

光阈值覆盖与必检测量是两种独立策略。`optical_thresholds` 只改变已经观察到的指标阈值；
`required_optics` 显式要求接口、lane、metric 存在，例如：

```ruby
CtxChecker::Policy.new(required_optics: [
  { interface: "Ethernet1/2", lane: 0, metric: :rx_power }
])
```

`lane: nil` 明确匹配设备未编号的单通道记录，不表示任意 lane。完整枚举缺少必检项为 fail；
命令不可用、部分数据或无法区分 lane 时为 unknown。必检项不能被 admin-down 自动豁免；
铜口不适用、无 DOM 或缺少功率/阈值也不会成为健康证明。未声明的阈值覆盖不会隐式变成必检项。

单次非零计数表示累计历史异常。传入 `Evaluator#call(snapshot, previous: earlier)` 可分析增量，但必须有
相同设备、严格递增采样时间及相同的 `discontinuity` 标识；正常增量还要求两次证据完整。
部分数据中已经证实的异常增量仍保留故障。该标识应由可靠的启动/清零证据生成；
目前 CLI 解析器不会把 `never` 或相对清零时长当成连续性证明。没有此证据会报告 unknown，不猜测回绕或速率。
采集器在每个 counter record 中保留 `sampled_at`，避免多命令合并后的增量使用错误的采样间隔。
设备级增量报告含累计值、delta、seconds、per_second；接口原有增量报告保持兼容。

资源默认 warning/critical 分别为 CPU 80/95%、内存 85/95%，达到即触发。这些值是可替换的运维策略，
不代表厂商硬件限制。时钟偏差默认 300 秒，NTP 绝对 offset 默认 100 ms；时钟参考命令采集时间，
离线调用应传真实观测时间。没有数值时不会以 0 代替；没有明确时区偏移时不猜测 CST/PST 等缩写。
组件名称精确匹配解析结果；可声明必需电源/风扇/温度传感器，未声明的空槽位不自动视为冗余故障。

### 当前查询范围

| 维度 | H3C | IOS / IOS-XE | NX-OS | Palo Alto |
| --- | --- | --- | --- | --- |
| 接口、计数 | `display interface`、`display counters inbound interface`、`display counters outbound interface` | `show interfaces` | `show interface` | `show interface all`、`show counter interface all` |
| 聚合成员 | `display link-aggregation verbose` | `show etherchannel summary` | `show port-channel summary` | `show lacp aggregate-ethernet all` |
| 光模块 | `display transceiver diagnosis interface` | `show interfaces transceiver detail` | `show interface transceiver details` | `show transceiver all` |
| BGP | `display bgp peer ipv4` | `show ip bgp summary` | `show bgp ipv4 unicast summary` | `show routing protocol bgp peer` |
| OSPF | `display ospf peer` | `show ip ospf neighbor` | `show ip ospf neighbors` | `show routing protocol ospf neighbor` |
| CPU | `display cpu-usage` | `show processes cpu` | `show system resources` | `show system resources` |
| 内存 | `display memory` | `show memory statistics` | 同上（一次采集） | 同上（一次采集） |
| 温度 | `display environment` | `show environment all` | `show environment` | `show system environmentals` |
| 环境 / 风扇 | `display fan` | 同上 | 同上 | 同上 |
| 电源 | `display power` | 同上 | 同上 | 同上 |
| 时钟 | `display clock` | `show clock detail` | `show clock` | `show clock` |
| NTP | `display ntp-service status` | `show ntp status` | `show ntp peer-status` | `show ntp` |
| 当前报警 | `display alarm active` | `show facility-alarm status` | unsupported | `show system state \| match alarm` |
| 设备计数 | unsupported | `show ip traffic` | `show ip traffic` | `show counter global` |

BGP 默认查询为 IPv4 unicast 公共/默认路由实例；不宣称 IPv6、EVPN 或所有 VPN 已经采集。
PAN 查询针对传统 routing engine；Advanced Routing 的不同命令与回显需要独立 Profile。
PAN 光模块 mW 转换为 dBm，0 mW 保持未知；未提供阈值时不能判断收发功率是否在正常范围。
PAN CPU `receive errors` 不等同于 CRC；计数器来源差异和缺失指标会保留在诊断中。
IOS-XE `show processes cpu` 仅覆盖 IOS 进程范围；PAN `show system resources` 仅覆盖管理面，不代表数据面。
NX-OS `show ntp status` 是 CFS 状态，本模块使用 `show ntp peer-status` 判断选中时源。
IOS/NX 设备计数限于 IPv4 软件栈，不代表所有 ASIC；PAN 累计值与命令共享采样 rate 分开，后者不作为本模块自有采样速率。
PAN 环境查询可能只有电压轨而没有 PSU 信息，不能据此认证电源冗余；VM 型号可能不支持物理环境查询。
NX 通用活动报警没有已确认查询，保留 unsupported；环境中的明确故障仍可分别报告。

### NX-OS 命令变体

每条固定查询仍对应独立解析器，共享语法通过小型可覆盖方法复用。NX-OS 的接口辅助字段、BGP 统计和
表格变体放在 NX-OS 层；IOS 的既有输入继续接受原有回归验证。

| 查询 | 已补齐的格式与证据边界 |
| --- | --- |
| `show interface` | Nexus 7000 详细字段、SVI autostate、聚合归属；未知管理状态仍为 partial。 |
| `show port-channel summary` | FEX 成员状态括号前空格、续行；坏的父聚合行不会污染上一组成员。 |
| `show interface transceiver details` | OLT 无单位 N/A、逐 lane 表头；缺失收发值仍未知，不复用前一 lane 的状态。 |
| BGP / OSPF | 每个 VRF/地址族的邻居数量校验、NX-OS 可选统计、损坏 scope 隔离、OSPFv2 IPv4 身份校验。BGP `No Cap` 保留身份与能力缺失诊断。 |
| `show environment` | 电源 Output/Input/Capacity 三列、N/A、风扇与模块状态；输入功率不作为额定容量。 |
| `show system resources` | CPU 1 秒窗口含 kernel；单侧或重复缓存字段不能确定性扣减内存使用量。 |
| `show ip traffic` | MBUF 丢弃、恢复信息、分片丢弃/超时；已出现的分片段缺字段则 partial。 |
| `show ntp peer-status` | 可选/紧贴 VRF、折行表头与行、紧凑图例；本地参考时钟不能证明外部同步。 |

命令执行失败隔离、来源完整性和报告覆盖率继续生效。Loopback/NVE 若缺少独立协议状态证据，健康判断仍
保留 unknown；尚未定义的计数或未知输出保持 partial，不能据此声称覆盖所有型号与软件版本。
新增样例的命令、版本、官方依据分别记录在
[接口与光模块](../spec/fixtures/ctx_checker/cisco_nxos/INTERFACE_SOURCES.md)、
[路由协议](../spec/fixtures/ctx_checker/cisco_nxos/PROTOCOL_SOURCES.md)、
[系统资源与环境](../spec/fixtures/ctx_checker/cisco_nxos/SYSTEM_VARIANT_SOURCES.md)、
[NTP 与时钟](../spec/fixtures/ctx_checker/cisco_nxos/TIME_SOURCES.md)中。

早期系统样例为依据官方格式构造的合成数据，来源和型号边界见
[H3C](../spec/fixtures/ctx_checker/h3c/SYSTEM_SOURCES.md)、
[Cisco](../spec/fixtures/ctx_checker/CISCO_SYSTEM_SOURCES.md)、
[PAN-OS](../spec/fixtures/ctx_checker/palo_alto/SYSTEM_SOURCES.md)。这些样例本身不是实机验证证明。

### 实机适配记录（2026-10-16）

已对 H3C S5130S-52S-EI（Comware 7.1.070 / R6343P08）与 Nexus C93108TC-EX
（NX-OS 10.2(5)）执行固定只读查询，并用脱敏、精简回显补充回归。
原始回显仅在私有采集目录保留，不进入源码；没有执行设备配置变更。

- H3C：支持 VLAN 续行、内部接口字段、带 Index 列和角色标记的聚合成员表；聚合父口状态只从完整接口证据关联，
  明确 DOWN 的物理成员仍报告故障并从可用容量中排除。时钟小数秒使用精确数值；OSPF 明确未配置与空回显分别诊断。
- NX-OS：支持聚合表分隔线粘连、铜口 `transceiver is not applicable`、扩展 IPv4 错误计数和 ACL 子表。
  `optics.applicable: false` 只在完整且无矛盾的证据下判为不适用，模块缺席和不支持 DOM 仍单独报告。
  `stomped_crc_errors`、`out_carrier_errors` 独立保留；总 CRC 已含 Stomped CRC，不能相加。
  完整管理口表若只提供流量总数和明确 connector 元数据，未提供的错误计数保存为 nil，不影响其他口的已知计数。
- 连接器：实机长行在第 80 列后出现行内分页提示，旧规则导致接口查询超时。`net-connector` 的 NX-OS profile
  将 PTY 宽度与分页匹配统一，并保留分页前的完整正文；不通过延长超时或自动重连掩盖问题。
- 能力边界：该 H3C 设备拒绝 BGP 和活动告警查询，但后续命令继续完成；物理 discard 未提供数值时仍未知。
  NX-OS 自定义时区名称不能独立证明 UTC 偏移；没有 DOM 测量的端口不能判定收发光正常。
  所有非零累计计数仍需连续性证据才能计算采样增量，不直接代表当前持续故障。

脱敏样例与来源说明见 [H3C 接口](../spec/fixtures/ctx_checker/h3c/LIVE_INTERFACE_SOURCES.md)、
[H3C 系统](../spec/fixtures/ctx_checker/h3c/LIVE_SYSTEM_SOURCES.md)与
[NX-OS 实机格式](../spec/fixtures/ctx_checker/cisco_nxos/LIVE_LAYOUT_SOURCES.md)。

```sh
docker exec -e RAILS_ENV=test motor-rails-1 bundle exec rspec spec/vendor/ctx_checker
docker exec motor-rails-1 bundle exec rubocop vendor/ctx_checker spec/vendor/ctx_checker
docker exec -e RAILS_ENV=test motor-rails-1 bundle exec rails zeitwerk:check
```

### Hillstone / StoneOS 实机接入（2026-10-16）

`platform: :hillstone` 或 `:stoneos` 使用独立 Profile；已在 SG-6000-A3700 / StoneOS 5.5R10P14
验证以下查询。每个脚本有独立解析器，失败不影响仍可执行的后续脚本；没有修改设备业务配置。

| 命令 | 投影与范围 |
| --- | --- |
| `show interface` | 物理、逻辑接口状态及聚合库存；H/A/L/P 分别解析 |
| `show interface counter` | 只包含返回的在线接口，采集 in/out discard |
| `show transceiver` | 逐模块 Tx/Rx dBm 与设备 normal range |
| `show cpu` / `show memory` | 当前 CPU、各时间窗口及内存占用；历史图表不充当当前测量 |
| `show environment` | 一次查询分别投影温度、风扇、电源 |
| `show clock` / `show ntp status` | 时钟证据、NTP 配置及最近同步尝试 |
| `show cpu-cntr` | 命名 CPU 端口及队列的设备计数，不合计重叠指标 |
| `show ip bgp summary` / `show ip ospf neighbor` | 当前仅验证未配置 BGP 与 OSPF 空回显边界 |

透明接口无 IP 时，P=DOWN 不等于链路 DOWN：保留原协议状态，使用 `protocol_applicable: false`
表示不适用。HA keep-up 不作为真实转发正常的证据。桥接口与冗余接口分别建模，不混入 LACP 聚合。
普通 admin-UP/link-DOWN 口按现有策略报告 warning；是否是闲置口不能由运行回显推断。

`show interface counter` 不提供 CRC/in_errors/out_errors；组合结果为这些指标保留 nil 和缺失诊断，
不会给未返回接口补零，也不会把 frames/octets 当错误包。`show cpu-cntr` 保留端口和 RX/TX 队列身份，
不拆解顶部数字粘连的流量汇总，不将内部端口映射为外部业务口。缺少连续性标识时，非零累计值仅为历史提示。

NTP `last_sync_status` 为 succeeded/failed/unknown，和系统 `synchronized` 分开；单次 Success 不能证明
当前系统同步，Error 单独报告最近尝试失败。`last_sync_at` 仅接受带偏移的时间；设备本地时间缺偏移时为 nil。
`show clock` 的自定义时区名称不能证明 UTC offset，因此不猜测时钟偏差。

能力边界：本机无活动 BGP/OSPF 邻居表，尚未验证相应行语法、全部 VRouter 或全部进程；BGP 未配置为 partial，
OSPF 空正文为 failed，均不代表协议健康。未观察到聚合成员时不宣称已完成 LACP 检查。
活动告警查询尚未适配，alarms 为 unsupported。不同 StoneOS 型号/版本仍需独立回显验证。

脱敏实机样例与来源见 [接口与光模块](../spec/fixtures/ctx_checker/hillstone/INTERFACE_SOURCES.md)、
[系统](../spec/fixtures/ctx_checker/hillstone/SYSTEM_SOURCES.md)、
[协议与时间](../spec/fixtures/ctx_checker/hillstone/PROTOCOL_TIME_SOURCES.md)、
[设备计数](../spec/fixtures/ctx_checker/hillstone/COUNTER_SOURCES.md)。

### Radware Alteon 实机接入（2026-10-16）

`platform: :radware_alteon` 使用 Alteon 独立 Profile，别名为 `:radware`、`:alteon`。
本轮回显来自 Alteon Application Switch 5424 S Perform / AlteonOS 32.4.15.0；
DefensePro 属于另一产品系列，不使用本目录。

| 命令 | 投影与范围 |
| --- | --- |
| `/info/link` | 数据物理口 `portN`、管理口 `mgmtN`；可配置 Alias 不作为稳定身份 |
| `/info/l3/ip` | 逻辑 IP 接口 `ipifN`；接口索引与 VLAN ID 分离，不把网关行当接口 |
| `/info/l2/trunk` / `/info/l2/lacp/dump` | 静态聚合成员、STP forwarding，以及 LACP 停用证据 |
| `/stats/port N/if` / `/stats/port N/ether` | 逐数据端口双向 errors/discards、CRC/FCS、carrier 错误 |
| `/info/transceiver` | 逐端口 Tx/Rx dBm；无设备阈值或告警时保持光学健康未知 |
| `/stats/mp/cpu` / `/stats/mp/mem` | 管理面 CPU 与 RAM；MP 进程虚拟内存、RSS 不作为整机占用率 |
| `/stats/sp 1/allutils` | 回显中的 SP CPU、内存表分别投影，检查声明的 SP 数量 |
| `/info/sys/temp` / `/info/sys/fan` / `/info/sys/ps` | 设备温度阈值、风扇状态、电源整体状态 |
| `/info/sys/general` / `/stats/sys/ntp` | 带明确 GMT offset 的当前时钟、NTP 历史计数与更新记录 |
| `/info/l3/bgp/summary` / `/info/l3/ospf/nbr` | 当前验证范围为查询 ADC 上明确的协议停用回显 |

端口计数查询先依据完整的 `/info/link` 发现数据端口，再为每个端口生成两条独立命令，
不使用固定型号端口列表或不支持的 `all` 参数。每条解析器绑定期望端口，其他端口的回显不能替代本次查询。
某个端口或某个方向查询失败时，其他查询继续；逻辑接口查询失败不阻断已有完整物理接口证据的计数发现。
`mgmtN` 不进入数据端口计数命令，当前管理口错误计数未适配。累计值与命令自带的 per-second 表严格分开，
CRC 不与总错误相加；缺少启动或清零标识时不计算采样增量。

逻辑接口回显只提供一列运行状态，管理状态和独立协议状态保持 unknown；明确 DOWN 仍报告故障。
静态聚合的 forwarding 不等于已知聚合链路 UP。LACP 实机样本全部为 off，活动成员表仍需补充；
遇到活动模式保留 partial 诊断，不复制静态聚合成员造成身份冲突。

旧 Alteon 软件存在光模块查询的已知缺陷。因此光模块目录由宿主提供的明确版本决定，
版本未知或不在已修复版本范围时为 unsupported，不根据型号推断。当前门槛为
30.5.9.0 起的 30.5 分支、31.0.6.0 起的 31.0 分支，以及 32.1.0.0 起的 32.x 分支；
不推测 33/34 等分支是否继承修复。版本使用四段十进制整数，不带空格、后缀或前导零。
这些条件只处理该历史缺陷，不表示所有满足条件的版本均已实机验证。传入实际目标已确认的软件版本：

```ruby
parser = CtxChecker::RuntimeParser.new(
  platform: :radware_alteon, model: "5424 S Perform", software_version: "32.4.15.0"
)
snapshot = CtxChecker::Collector.new.collect(
  target: { host: "192.0.2.250", platform: :radware_alteon,
            model: "5424 S Perform", software_version: "32.4.15.0" },
  connector: connector,
  dimensions: %i[interfaces counters aggregation optics cpu memory temperature environment power clock ntp]
)
```

光模块的短 NA 行、长 NA 行均不能证明无模块、不支持 DOM 或光功率正常。
NTP 统计只提供历史请求、响应、更新数量，不能确认当前同步，也不推导最近一次尝试成功。
完整 BGP/OSPF disabled 回显使本次查询上下文的该维度为 not_applicable；明确必检策略仍会报告未启用。该结论不覆盖其他 vADC 或 IPv6，活动邻居格式仍待验证。
活动告警、HA 冗余健康、SLB 虚拟服务和后端服务健康尚未适配；设备资源检查通过不代表这些业务可用。

脱敏回显、合成负向样例与适配边界见
[接口、计数与光模块](../spec/fixtures/ctx_checker/radware_alteon/INTERFACE_SOURCES.md)、
[系统资源与环境](../spec/fixtures/ctx_checker/radware_alteon/SYSTEM_SOURCES.md)、
[协议与时间](../spec/fixtures/ctx_checker/radware_alteon/PROTOCOL_TIME_SOURCES.md)。
这些回归验证已观察到的格式，不构成其他型号或版本的实机认证。

### 语义依据

* [RFC 2863：接口计数器与连续性](https://www.rfc-editor.org/rfc/rfc2863.html)
* [RFC 2328 §10.4：OSPF 邻接形成](https://datatracker.ietf.org/doc/html/rfc2328#section-10.4)
* [Cisco DOM 与模块阈值](https://www.cisco.com/c/en/us/support/docs/switches/catalyst-9200-switch-stack/222738-troubleshoot-fiber-links-on-catalyst-900.html)
* [H3C 光模块诊断命令](https://www.h3c.com/cn/d_202308/1917164_30005_0.htm)
* [PAN-OS 11.1 操作命令层次](https://docs.paloaltonetworks.com/ngfw/pan-os-cli-quick-start/cli-command-hierarchy/pan-os-11-1-cli-ops-command-hierarchy)
* [PAN 接口计数器命令](https://docs.paloaltonetworks.com/pan-os/u-v/pan-os-device-telemetry-metrics-reference/device-health-and-performance/metric-dt-dhp-118)
* [PAN CPU 接口错误计数语义](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA14u0000004Le6CAE&lang=en_US)
* [PAN 光功率 0 mW 采样边界](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA14u000000CrOzCAK&lang=en_US)
* [PAN 聚合接口及硬件表格式](https://docs.paloaltonetworks.com/vm-series/deployment/private-cloud/set-up-a-vm-series-firewall-on-an-esxi-server/install-a-vm-series-firewall-on-vmware-vsphere-hypervisor-esxi/configure-link-aggregation-control-protocol)
* [Cisco IOS 队列丢弃计数](https://www.cisco.com/c/en/us/support/docs/switches/catalyst-9300-series-switches/225791-frequently-asked-questions-output.html)


## 配置驱动的检查适用性

链路聚合、BGP 和 OSPF 并非所有设备必备。`Applicability` 使用本次目标的完整配置判断功能是否配置；厂商语法留在配置解释器，采集器和健康规则只依赖 `configured` / `not_configured` / `unknown` 三态。当前支持 Comware、IOS/IOS-XE 和 NX-OS 的配置判断；其他平台保持 unknown，不按型号或设备角色猜测。

```ruby
applicability = CtxChecker::Applicability.from_configuration(
  platform: target.fetch(:platform), text: running_configuration, complete: true
)
snapshot = CtxChecker::Collector.new.collect(
  target: target, connector: connector, applicability: applicability
)
report = CtxChecker::Evaluator.new(policy: policy).call(snapshot)
```

调用方须使用同一设备、同一检查批次取得的完整配置；不要把旧备份当作当前未配置的证明。配置未取得、部分回显、无法确认格式时，继续独立执行运行命令。确认未配置的可选维度标记 `not_applicable`，跳过相关查询并排除健康覆盖率分母；报告保留配置摘要，不保存配置正文。只请求不适用维度时不会打开设备连接。单条命令明确声明本次查询范围内的功能 disabled，或聚合表明确零组、且回显完整时也可得出不适用；只有某个地址族无邻居、空正文或执行失败仍不足以证明整个功能未启用。

如果策略通过 `expected_bgp`、`expected_ospf`、`required_members`、`minimum_active_members` 或 `required_dimensions` 明确要求该能力，已确认未配置会产生 `required_feature_not_configured` 失败，不能用不适用绕过业务要求。已配置但运行查询为空仍是 unknown；本次功能判断不将“零邻居”解释为“未配置协议”。
