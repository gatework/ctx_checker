# Alteon protocol and time fixtures

The device-derived fixtures were collected read-only on 2026-10-16 from an
Alteon 5424 S Perform running AlteonOS 32.4.15.0. Device addresses, hardware
identifiers and unrelated system metadata are omitted.

| Fixture | Command | Proven scope |
| --- | --- | --- |
| `general.txt` | `/info/sys/general` | Current clock and explicit GMT offset; boot/apply/save times are separate |
| `ntp.txt` | `/stats/sys/ntp` | Primary/secondary cumulative requests, responses and updates; current synchronization unavailable |
| `bgp_disabled.txt` | `/info/l3/bgp/summary` | BGP explicitly disabled in the queried ADC context |
| `ospf_disabled.txt` | `/info/l3/ospf/nbr` | OSPF explicitly disabled in the queried ADC context |
| `bgp_menu.txt`, `ospf_menu.txt` | `/info/l3/bgp`, `/info/l3/ospf` | Navigation output is not neighbor evidence |
| `command_error.txt` | `/stats/port all/if` | Explicit rejected syntax; the inventory drives individual port queries |

Protocol tests also use synthetic unfamiliar rows as negative examples. No
active BGP or OSPF neighbor output was captured, so these parsers do not claim
to support active legacy or FRR tables, all vADC contexts, or IPv6 sessions.
The explicit disabled state does not prove that a configured or expected peer
is healthy.

NTP statistics do not expose stratum, leap state, offset, or current system
synchronization. A historical update can precede later failed attempts. Its
timezone is also absent, so neither a last-attempt success nor a zoned sync
timestamp is inferred. The six integer counters retain informational category
and have no reset/discontinuity evidence.

Official references:

- [NTP configuration and monitoring commands](https://support.radware.com/app/answers/answer_view/a_id/1017579/~/how-to-configure-ntp-service-in-alteon)
- [BGP legacy and FRR implementation differences](https://portals.radware.com/ReleaseNotes/Alteon_Release_Notes_33_0_0_10/Alteon_Release_Notes/AlteonOS-33_0_0_10-Release_Notes.1.13.html)
- [HA runtime output and backup role](https://support.radware.com/app/answers/answer_view/a_id/1031264/~/alteon---getting-session-entries-on-the-backup-device)
- [All virtual-server information command](https://support.radware.com/app/answers/answer_view/a_id/1009417/~/how-to-show-information-and-statistics-on-all-virts-)
- [Separate health checks for each real-server service](https://support.radware.com/app/answers/answer_view/a_id/15073/~/are-health-checks-performed-for-each-service-on-the-same-real-server%3F)

HA and application-service observations are research context only. This profile
does not project them into unrelated hardware or routing dimensions.
