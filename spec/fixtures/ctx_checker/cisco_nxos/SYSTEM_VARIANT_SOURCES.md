# NX-OS system command variant sources

These fixtures are synthetic, reduced examples following Cisco's documented CLI
layouts. They are not captures from the user's devices and do not establish
support for every platform or NX-OS release. Read on 2026-10-16.

- `environment_n9508.txt`: [Cisco Nexus 9508 NX-OS hardware guide, Managing the Switch](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/nexus9000/hw/n9508_hig/guide/b_n9508_nxos-mode_hardware_install_guide/b_n9508_hardware_install_guide_chapter_01001.html).
  Combines documented two/three power-reading layouts, unavailable `N/A W`,
  module rows, fan state/zone/filter rows, and temperature thresholds. Input
  watts are separate from output watts and rated capacity. Fan `None` means no
  affirmative status: retain unknown rather than assume a healthy fan.
- `resources_n9k.txt`: [Cisco Nexus 9000 NX-API system commands, Release 9.3(x)](https://developer.cisco.com/docs/cisco-nexus-9000-series-nx-api-cli-reference/latest/system-commands/)
  documents aggregate/per-core percentage rounding and kilobyte memory totals.
  [Cisco Nexus 9000 troubleshooting guide, Release 10.4(x)](https://www.cisco.com/c/en/us/td/docs/dcn/nx-os/nexus9000/104x/troubleshooting/cisco-nexus-9000-series-nx-os-troubleshooting-guide-104x/m-troubleshooting-tools-and-methodology.html)
  defines CPU states as the last one second and explains that buffers/cache are
  already included in used memory. Negative, missing-unit and repeated cache
  examples in the spec are deliberate malformed-input tests.
- `device_counters_n5500.txt`: [Cisco Nexus 5500 NX-OS unicast routing reference, Show Commands](https://www.cisco.com/en/US/docs/switches/datacenter/nexus5500/sw/command/reference/unicast/7x/n5500-ospf_cmds_show.html).
  Adds optional restart-recovery and MBUF pull-up failure fields, plus IPv4
  fragment drops/timeouts. Recovery is retained as informational context; a
  successful restart-recovery count alone is not a packet error. Later ICMP
  counters remain outside the IPv4 control-plane counter scope. The documented
  `Statistics last reset: never` is not a reliable continuity epoch across
  device restarts, so no sampling discontinuity is inferred from it.
