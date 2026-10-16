# NX-OS time command variants

Checked on 2026-10-16. `ntp_variants.txt` and the bodies in `nxos_time_spec.rb`
are synthetic regression inputs with documentation addresses. They are not
device captures or certification of a hardware or software release.

- [Nexus NTP server/client verification](https://www.cisco.com/c/en/us/support/docs/switches/nexus-9000-series-switches/221746-configure-network-time-protocol-on-nexus.html)
  shows the optional blank VRF and a VRF adjoining the delay value. The selected
  `127.127.1.0` source represents the device's local reference clock; it cannot
  prove synchronization to an external source. Mapped IPv4 addresses are normalized
  before identity and local-reference checks. A configured clock source alone is
  not proof of synchronization.
- [Nexus 5500 7.x NTP guide](https://www.cisco.com/c/en/us/td/docs/switches/datacenter/nexus5500/sw/system_management/7x/b_5500_System_Mgmt_Config_7x/configuring_ntp.html)
  documents the table without a VRF column and compact legend spacing.
- [Nexus 3000/9000 NTP peer status](https://developer.cisco.com/docs/cisco-nexus-3000-and-9000-series-nx-api-rest-sdk-user-guide-and-api-reference-release-9-3x/querying-ntp-peer-status/)
  includes a 9.2(1) example with wrapped headers and peer rows. Only the documented
  continuations are joined; truncated rows never consume a following peer or count.
- [Nexus 7000 8.3(1) clock commands](https://developer.cisco.com/docs/nx-api-cli-reference-for-the-cisco-nexus-7000-series-platform/syscli-commands/)
  places the source before the timestamp. Existing clock grammar handles either
  ordering. Unknown timezone abbreviations remain unknown absolute time.

Peer reachability is an octal bitmap, not a decimal counter. Selection, valid
stratum, complete table layout and matching peer totals are required together.
The parser does not infer a software version from the command output or apply
the 10.1(1) stratum restriction to older releases without version evidence.
