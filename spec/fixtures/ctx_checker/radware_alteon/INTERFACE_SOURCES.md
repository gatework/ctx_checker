# Alteon interface evidence

`link_5424_32415.txt` is a read-only capture from an Alteon Application Switch
5424 S running AlteonOS 32.4.15.0 on 2026-10-16. The source command is
`/info/link`. It contains port state and numbers only, without target addresses,
device credentials or serial numbers. Tests mutate this capture for malformed,
duplicate, truncated and unknown-state cases; those mutations are synthetic.

Management ports and data ports have overlapping numeric IDs. The stable local
identities are `mgmt1`, `mgmt2`, and `port1` through the observed data-port range.
The configurable `Alias` column is not an interface identity. `disabled` confirms
an administrative disable; `up` and `down` do not independently establish the
administrative state. No Layer 3 protocol state is inferred from a physical link.

`trunk_5424_32415.txt` comes from `/info/l2/trunk` and confirms a static trunk with
two members in STP forwarding state. It does not include aggregate link state.
`lacp_5424_32415.txt` comes from `/info/l2/lacp/dump`; every port has LACP `off`
and no selected or attached aggregator. It is independent of static trunk
membership. Active LACP mode mutations in tests demonstrate an adaptation gap,
not validation of active LACP behavior. Until an operational active-LACP sample
is available, active rows remain partial rather than fabricating member state
or duplicating the static-trunk records.

`port_if_5424_32415.txt` and `port_ether_5424_32415.txt` come from
`/stats/port 27/if` and `/stats/port 27/ether`. Dynamic query parsers bind the
expected data-port identity and reject a response for another port. Interface
Discards and Errors rows are cumulative; the separately labeled per-second
table never replaces those values. IEEE FCS errors map to CRC errors, while
carrier-sense errors remain a separate outbound metric. Alignment errors and
other Ethernet subcounters are not added to the interface totals. `NA`, absent,
malformed and duplicated values stay unknown. These commands supply no reliable
counter reset identity, so they do not establish continuity for sampling deltas.

The Ethernet subcounters use `scope: mac`. FCS counts received frames, normalized
to packet counts. Carrier-sense errors count failed transmission attempts and
use `unit: events`, not a count to add to the interface output-error total.
Their definitions follow [RFC 3635](https://www.rfc-editor.org/rfc/rfc3635.html).

The official [Alteon transceiver information article](https://support.radware.com/app/answers/answer_view/a_id/1009416/~/alteon-transceiver-information)
documents `/info/transceiver`, its optical Tx/Rx readings in dBm, and its
standalone/ADC-VX scope. It does not document optical thresholds. Earlier
versions have a documented disruptive defect in this read command, fixed in
[30.5.9.0](https://portals.radware.com/ReleaseNotes/Alteon_Release_Notes_30_5_19_0/Alteon_Release_Notes/AlteonOS-30_5_19_0-RN.1.65.html),
[31.0.6.0](https://portals.radware.com/ReleaseNotes/Alteon_Release_Notes_31_0_20_0/Alteon_Release_Notes/AlteonOS-31_0_20_0-RN.1.70.html),
and [32.1.0.0](https://portals.radware.com/ReleaseNotes/Alteon_Release_Notes_32_4_20_0/Alteon_Release_Notes/AlteonOS-32_4_20_0-RN.1.94.html).
These references do not constitute live validation of those older branches.

`transceiver_5424_32415.txt` is the successful `/info/transceiver` capture from
the same 32.4.15.0 device after native connector menu/pagination handling was
corrected. Vendor names, part numbers and serial numbers have been replaced.
The two measured ports retain their original measurements; all 28 observed
rows remain present. Short `port NA` rows and long all-NA rows do not establish
module absence, unsupported DOM or healthy optics. The command reports no
thresholds or alarms, so even numeric optical measurements remain unknown for
health assessment until independent thresholds are available.

`ip_5424_32415.txt` is the successful `/info/l3/ip` capture after pagination
handling was corrected. Addresses are replaced with documentation addresses,
and VLAN IDs are replaced with an example ID. The eight IP-interface indexes
remain independent of VLAN IDs and physical data-port numbers. Only rows in
the explicitly terminated interface section become interface records; numbered
default gateways are excluded. The source reports one operational state, with
no independent administrative or line-protocol state. IPv6 link-local rows have
not been validated and cause partial logical-interface coverage when present.
