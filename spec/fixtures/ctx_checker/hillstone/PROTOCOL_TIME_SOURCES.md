# StoneOS protocol and time evidence

The `clock`, `ntp_status`, `ntp_status_mixed`, and `bgp_unconfigured` fixtures preserve
the line structure captured on a StoneOS firewall on 2026-10-16. NTP server identities
are replaced with documentation addresses and an example domain. Private captures remain outside the
fixture directory. The device returned no body for `show ip ospf neighbor`; this is
an unavailable observation, not evidence of an empty neighbor inventory.

Command references:

- [StoneOS Routing 5.5R4](https://kb.hillstonenet.com/en/wp-content/uploads/2017/01/StoneOS_CLI_User_Guide_Routing_5.5R4.pdf),
  printed pages 64–65 and 91: BGP summary and OSPF neighbor queries can be scoped to
  a VRouter; OSPF queries can also select a process. Neither missing scope nor an
  unconfigured default query establishes coverage of other routing instances.
- [StoneOS System Management 5.5R6](https://kb.hillstonenet.com/en/wp-content/uploads/2018/08/StoneOS_CLI_User_Guide_System_Management_5.5R6.pdf),
  printed pages 72–76: `show clock` and `show ntp status` are read-only queries.
  Timezone names may be customized and daylight saving may apply. The documented
  NTP output can contain configuration alone, without system synchronization state.

The initial capture showed failed NTP attempts. A later capture at 04:01 UTC showed
one peer's latest attempt as `Success` and the other as `Error`; the mixed fixture
preserves that transition. Both attempt outcomes remain separate from current system
synchronization. Local timestamps without an explicit UTC offset remain unavailable
for cross-device time comparisons. Enabled NTP and configured servers do not imply
synchronization. Active BGP/OSPF table formats have not yet been observed;
unfamiliar output remains unknown instead of being assigned Cisco grammar or default scope.
