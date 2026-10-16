# NX-OS 接口命令样本来源

核对日期：2026-10-16。以下文件是依据 Cisco 官方输出格式编写的合成回归样本，接口、地址、计数和序列号已替换；不是现场采集，也不证明对应系列的全部硬件/软件版本均已验证。

| 样本 | 官方格式来源 | 验证范围 |
| --- | --- | --- |
| `interface_n7000_83.txt` | [Cisco DevNet Nexus 7000 Interface Commands](https://developer.cisco.com/docs/nx-api-cli-reference-for-the-cisco-nexus-7000-series-platform/interface-commands/)；Ethernet 样例注明 NX-OS 8.3(1)，SVI 样例注明 8.2(1) | Ethernet RX/TX 的五类错误/丢弃指标、CRC/FCS 标签、成员归属、秒级速率与硬件描述行；SVI 的 autostate 后缀。此文件组合两个版本的命令片段，不代表同一次设备采样。 |
| `aggregation_fex_7x.txt` | [Nexus 5600 NX-OS Interfaces Command Reference, Release 7.x](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/nexus5600/sw/command/reference/interfaces/7x/n5600_if_cmd_ref/n5600_if_cmds_show.html) 的 `show port-channel summary` | 双行表头、FEX 成员标志前的空格、折行成员，以及活动、DOWN、挂起、空成员聚合。状态组合为合成用例。 |
| `optics_olt_106.txt` | [Nexus 9000 NX-OS Interfaces Configuration Guide, Release 10.6(x), Basic Interface Parameters](https://www.cisco.com/c/en/us/td/docs/dcn/nx-os/nexus9000/106x/configuration/interfaces/cisco-nexus-9000-series-nx-os-interfaces-configuration-guide-release-106x/m_configuring_basic_interface_parameters_93x.pdf) 的 SFP-10G-OLT20-X 样例 | Tx/Rx 当前值为不带单位的 N/A，同时保留带 dBm 的四级阈值。N/A 是不可用值，不能转为 0 或健康。 |

`nxos_interfaces_spec.rb` 还使用以下公开格式构造边界用例：

- [Nexus 9000 NXDB Release 7.x 的 show interface 输出](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/nexus9000/sw/7-x/nxdb/configuration/guide/b_Configuring_NXDB_for_Nexus_9000_and_Communicating_with_NSXv_Controllers/b_Configuring_NXDB_for_Nexus_9000_and_Communicating_with_NSXv_Controllers_appendix_01001.html)：SVI 的管理关闭原因出现在 line protocol 字段之前。只使用有明确语义的管理关闭标记。
- [Nexus 3000 NX-OS Interfaces Configuration Guide, Release 9.3(x)](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/nexus3000/sw/interfaces/93x/configuration/guide/b-cisco-nexus-3000-nx-os-interfaces-configuration-guide-93x/b-cisco-nexus-3000-nx-os-interfaces-configuration-guide-93x_chapter_010.html)：每个光模块 lane 的测量表头、功率和阈值单位。测试对既有 `optics.txt` 删除表头或破坏 lane 编号，验证未知数据不会复用前一 lane。

截断、未知状态/协议、非法单位和错误 lane 均为主动构造的负向样本，用于验证诊断与隔离边界，不能当作 Cisco 官方设备行为。
