# NX-OS live layout regressions

The 2026-10-16 read-only device collection exposed these formats:

- `show port-channel summary`: full-width separator lines concatenate with the
  next table header or group row. The minimal example is inline in
  `nxos_live_layout_spec.rb`; group identifiers are replaced.
- `show interface transceiver details`: copper ports explicitly report
  `transceiver is not applicable`. Inapplicability is distinct from an absent
  module or unsupported digital optical monitoring.
- `show ip traffic`: additional IPv4 software-stack counters, adjacent cells
  without a comma, the repeated option-processing failure cell, an ACL filter
  subsection, and a per-protocol fragmentation context table.
- `show interface`: the completed subsequent capture provides management
  connector metadata, single-line SVI packet totals, loopback carrier errors,
  and the separate stomped CRC field. These cases are authored as small
  synthetic grammar examples in `nxos_live_interfaces_spec.rb`. The earlier
  interrupted capture is used only as evidence of an incomplete collection.

`device_counters_n9k_live_layout.txt` retains only the relevant grammar. Counter
values are synthetic. It contains no device identity, addresses, credentials or
raw session transcript. Contradictory and truncated examples are generated in
the spec and are not claimed to be actual device output.

ACL and reverse-path filter drops remain policy counters. Packet snooping,
migration and encapsulation totals are informational. Cumulative error/discard
totals are not evidence of a current fault rate without a comparable sample and
an established counter discontinuity boundary.

[Cisco's Nexus 9000 CRC guide](https://www.cisco.com/c/en/us/support/docs/switches/nexus-9000-series-switches/216239-nexus-9000-cloud-scale-asic-crc-identifi.html)
confirms that total CRC includes stomped frames. `stomped_crc_errors` is retained
independently and is never added to `crc_errors`; its absence on older releases
does not imply zero. The displayed `out_carrier_errors` is also independent of
`out_errors`. Neither counter implies a current fault rate from a single sample.

A complete management-interface table that explicitly finishes with recognized
transceiver and connector metadata but supplies no error fields yields nil
error/CRC measurements. Missing metadata, partially present error fields, and
invalid values remain incomplete. Logical interfaces without a separate line
protocol field retain unknown protocol state.
