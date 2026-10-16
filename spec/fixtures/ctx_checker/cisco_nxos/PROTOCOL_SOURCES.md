# NX-OS protocol fixture provenance

These are synthetic, sanitized CLI fixtures, not captures from a live device.
Addresses use documentation ranges; counts, ASNs, process tags and VRFs are
test data. Variants in `nxos_protocols_spec.rb` deliberately mutate declarations,
rows and capture completeness to verify conservative parsing.

- `bgp_summary.txt`: documented summary columns, configured/capable peer counts,
  dampening statistics and inbound soft-reconfiguration statistics from
  [Cisco Nexus 9000 NX-API CLI BGP commands, 9.3(x)](https://developer.cisco.com/docs/cisco-nexus-9000-series-nx-api-cli-reference/latest/bgp-commands/).
  The CLI sample was introduced in NX-OS 9.2(1). Configured peer counts are checked
  independently per VRF/AF. Capable peers is not treated as an established count.
  The documented `0 (No Cap)` annotation preserves the peer identity and counts
  it as an observed neighbor, but records unknown state, unavailable prefix count
  and an explicit capability issue. The current health model cannot express
  address-family capability separately from session state; this annotation must
  never become a healthy zero-prefix neighbor.
- The meaning of the BGP global summary fields is described by
  [Cisco Nexus 3000 NX-OS Basic BGP, 9.2(x)](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/nexus3000/sw/unicast/92x/configuration/guide/b-cisco-nexus-3000-series-nx-os-unicast-routing-configuration-guide-92x/b-cisco-nexus-3000-series-nx-os-unicast-routing-configuration-guide-92x_chapter_01001.html).
- `ospf_neighbors.txt`: process/VRF header, declared total and neighbor columns
  follow [Cisco Nexus 3000/9000 IP OSPF Neighbor Details, 10.3(x)](https://developer.cisco.com/docs/cisco-nexus-3000-and-9000-series-nx-api-rest-sdk-user-guide-and-api-reference-release-103x/querying-ip-ospf-neighbor-details/).
  The CLI sample was introduced in NX-OS 7.0(3)I7(3). Multi-process, subinterface,
  absent role and 2WAY rows are constructed coverage variants. The summary does
  not establish local role or network type, so these remain unknown.

Unknown syntax, malformed scopes, inconsistent counts, omitted neighbor rows and
incomplete captures retain partial/failed coverage rather than implying health.
