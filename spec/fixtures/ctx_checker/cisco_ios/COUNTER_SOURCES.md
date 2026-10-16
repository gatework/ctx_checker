# Cisco interface counter semantics

IOS `input errors`, `output errors`, `CRC` and explicit input/output discard
labels remain separate counters. CRC can overlap with input errors and must
not be added to produce an error total. NX-OS additionally retains stomped CRC
and carrier errors separately.

The `Input queue` drops field is an ingress queue measurement. It is not an
exact substitute for SNMP `ifInDiscards`: Cisco documents that queue-limit
drops are included in the former, while no-buffer drops contribute to both.
The parser therefore marks this source with `scope: queue`.
Reference: [Cisco SNMP counter FAQ](https://www.cisco.com/c/en/us/support/docs/ip/simple-network-management-protocol-snmp/26007-faq-snmpcounter.html).

`Total output drops` has no unit in the displayed field. Its unit depends on
the platform, software release and configuration; Cisco documentation includes
both byte-count and packet-count variants. The generic parser preserves the
value with `unit: unknown` and `scope: queue`; it must not be compared with a
packet-count threshold until the unit is independently established.
Reference: [Understand Output Drops on Catalyst 9000 Switches](https://www.cisco.com/c/en/us/support/docs/switches/catalyst-9600-series-switches/220491-understand-output-drops-on-high-speed-in.pdf), page 5.
The later [Cisco TAC unit clarification](https://community.cisco.com/t5/tkb-ネットワーキング-ドキュメント/catalyst-3650-3850-9000-total-output-drop-の表記について/ta-p/4745407)
documents the default changing to packets for newer Catalyst 9000 releases.

Counter-like numbers in interface descriptions are synthetic regression inputs,
not measurements. They must neither create observations nor invalidate actual
counter rows as duplicate identities.
