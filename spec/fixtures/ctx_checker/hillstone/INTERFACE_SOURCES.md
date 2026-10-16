# Hillstone interface and optics evidence

`interfaces_live.txt`, `interface_counters_live.txt` and `optics_live.txt` retain the syntax of read-only commands
captured on 2026-10-16. The interface fixture is an excerpt: unused ports are
omitted; addresses, MACs, descriptions and module identities are replaced.
Tests that mutate these fixtures are synthetic regressions, not additional live
device observations.

- `show interface`: StoneOS H/A/L/P state columns, including separate link and
  IP protocol states. `0.0.0.0/0` identifies an unnumbered interface; the original
  protocol-down fact is retained with `protocol_applicable: false`.
- `show transceiver`: two modules with dBm readings and per-module normal
  ranges. Normal ranges become warning thresholds; the output supplies no alarm
  severity or explicit normal-alarm flag. Missing ranges remain unavailable.
- The summary proves an empty aggregation inventory only when fully parsed.
  An aggregate row does not prove membership, so it produces a partial
  aggregation record with an unavailable member.
- No interface CRC/error counters are fabricated from link status or throughput.
  Captured `show interface ethernet0/0` contains no error counters. The observed
  device rejects `show interface all` and parameterless `show lacp`.
- `show interface counter`, supplied by the operator and verified against the
  device, lists online interfaces only. Its frame/byte columns are traffic
  totals; only the two discard columns map to error-health metrics. Missing
  offline interfaces do not imply zero counts, and missing CRC/error columns
  remain unavailable. Cumulative counts provide no counter-reset epoch.

Official references:

- [StoneOS 5.5R1 CLI User Guide](https://kb.hillstonenet.com/en/wp-content/uploads/2015/06/StoneOS_CLI_User_Guide_5.5R1.pdf),
  interface state definitions and `show interface` / named-interface commands.
- [StoneOS 5.5R5 CLI User Guide](https://kb.hillstonenet.com/en/wp-content/uploads/2017/11/StoneOS_CLI_User_Guide_Complete_Book_5.5R5-1.pdf),
  optical-module inspection with `show transceiver [interface-name]`.
- [StoneOS 5.5R10F6 release notes](https://www.hillstonenet.com/wp-content/uploads/StoneOS-5.5R10F6-Release-Note.pdf),
  optical-module Part Number metadata extension.
- [Hillstone device troubleshooting guide](https://kb.hillstonenet.com/en/wp-content/uploads/2016/05/Hillstone-All-Series-Device-Troubleshooting-and-Debug-Guide.pdf),
  hardware counters are a separate controller-port command, not interface status.
