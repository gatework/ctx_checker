# Cisco system command fixtures

These fixtures are synthetic examples authored for parser regression tests from the
documented CLI grammar. Values, identities, timestamps, addresses and serials are
invented. They are not device captures or evidence of model certification.

Official references checked on 2026-10-16:

| Fixture / command | Reference and supported scope |
| --- | --- |
| IOS `cpu.txt` / `show processes cpu` | [IOS command reference](https://www.cisco.com/c/en/us/td/docs/ios/fundamentals/command/reference/cf_book/cf_s3.html): 5-second total includes interrupt work; 1-minute and 5-minute windows stay separate. On IOS-XE this represents IOS process scope, not all Linux processes. |
| IOS `memory.txt` / `show memory statistics` | [IOS memory reference](https://www.cisco.com/c/en/us/td/docs/ios/fundamentals/command/reference/cf_book/cf_s2.html): pool accounting in bytes, both table and Pool Total forms. |
| IOS `environment.txt` / `show environment all` | [Catalyst 9300 IOS-XE command reference](https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst9300/software/release/17-9/command_reference/b_179_9300_cr/interface_and_hardware_commands.html): active switch sensors, temperature thresholds and power table; this does not claim full stack coverage. |
| IOS `environment_asr.txt` | [IOS environment reference](https://www.cisco.com/c/en/us/td/docs/ios-xml/ios/fundamentals/command/cf_command_ref/show_through_show_fm_summary.html): ASR sensor table and state semantics; fan speed alone does not establish sensor health. |
| IOS clock and `ntp.txt` | [IOS clock and NTP reference](https://www.cisco.com/c/en/us/td/docs/ios-xml/ios/bsm/command/bsm-cr-book/m_bsm-cr-n1.html): explicit system synchronization, stratum and signed offset in milliseconds. An ambiguous timezone abbreviation is retained as unknown absolute time. |
| IOS `alarms.txt` / `show facility-alarm status` | [ISR 4000 process health monitoring](https://www.cisco.com/c/en/us/td/docs/routers/access/isr4400/software/configuration/xe-17/isr4400-sw-config-xe-17/process_health_monitoring.html) and [NCS 520 monitoring alarms](https://www.cisco.com/c/en/us/td/docs/routers/ncs5xx/ncs520/configuration/guide/chassis/17-1-1/b-Chassis-Guide-xe-17-1-1-ncs520/m-configuring-monitoring-alarm-ncs520.html): active conditions with optional timestamp column. Unsupported models retain unsupported command coverage. |
| IOS `device_counters.txt` / `show ip traffic` | [Cisco CPU troubleshooting](https://www.cisco.com/c/en/us/td/docs/switches/lan/catalyst3750/software/troubleshooting/cpu_util.html): cumulative IPv4 software-stack errors and drops; later ICMP/TCP/UDP sections are not merged into the IPv4 scope. |
| NX-OS `resources.txt` / `show system resources` | [NX-OS fundamentals commands](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/nexus5000/sw/command/reference/fund/n5k-fund-cr/n5k-fund_cmds_show.html) and [NX-OS memory troubleshooting](https://www.cisco.com/c/en/us/td/docs/dcn/nx-os/nexus9000/104x/troubleshooting/cisco-nexus-9000-series-nx-os-troubleshooting-guide-104x/m-troubleshooting-memory.html): CPU busy is 100 minus idle; reported used memory can include reclaimable cache. |
| NX-OS `environment.txt` / `show environment` | [Nexus 7000 hardware management](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/hw/nexus7000/installation/guide/n7k_hig_book/n7k_managing_sys_hw.html): component sections, per-sensor minor/major thresholds, PSU and module states. Hardware clock modules belong to environment, not wall-clock time. |
| NX-OS `ntp.txt` / `show ntp peer-status` | [Nexus 7000 NX-API security commands](https://developer.cisco.com/docs/nx-api-cli-reference-for-the-cisco-nexus-7000-series-platform/security-commands/) and [Nexus 1000V command reference](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/nexus1000/sw/4_2_1_s_v_2_2_1/command/reference/n1000v_cmds/n1000v_cmds_show.pdf): selected peer, octal reach register and VRF. NX-OS `show ntp status` reports CFS state, so it is not used to infer synchronization. |
| NX-OS clock | [Nexus NTP configuration and verification](https://www.cisco.com/c/en/us/support/docs/switches/nexus-9000-series-switches/221746-configure-network-time-protocol-on-nexus.html): `show clock` body and source. A configured source alone does not prove current synchronization. |
| NX-OS `device_counters.txt` / `show ip traffic` | [NX-OS unicast command reference](https://www.cisco.com/en/US/docs/switches/datacenter/sw/4_2/nx-os/unicast/command/reference/l3_cmds_show.html): IPv4 software processing errors only. Relative reset ages and `never` are not counter continuity tokens. |

The generic NX-OS profile deliberately has no active-alarm command. Environmental
faults remain analyzable in their own dimensions; a historical log is not an active
alarm inventory. Unrecognized platform variants remain partial or failed evidence.

For a complete, consistent buffers-and-cache line, NX-OS memory is represented with
the `used_minus_cache` basis. `used_bytes` is the adjusted value, `free_bytes` stays
the reported physical free value, and `available_bytes` is total minus adjusted
used. This accounting is not a claim that every cached page can immediately be
reclaimed; device pressure states remain independent evidence. With no cache proof,
the basis remains `used_including_cache` and healthy memory pressure is not inferred.

The Nexus 7000 hardware guide defines MajorThresh/MinorThres alarms when the
threshold is exceeded (`high_comparison: gt`) and defines -127 as an unavailable
threshold. Catalyst temperature grammar has no verified equality convention here;
its comparison stays unspecified so an exact threshold hit cannot silently pass.
