# S5130S R6343 system captures

The `*_s5130s_r6343.txt` files in this directory are sanitized command bodies captured
on 2026-10-16 from an H3C S5130S-52S-EI running Comware 7.1.070, Release 6343P08.
They contain no device names, credentials or serial numbers. The NTP server and
reference address were replaced with the documentation address `192.0.2.123`.
Other measured values and command grammar are retained. These files cover one
observed software/model combination, not every Comware device.

| Fixture prefix | Read-only command |
| --- | --- |
| optics | display transceiver diagnosis interface |
| ospf_unconfigured | display ospf peer |
| cpu | display cpu-usage |
| memory | display memory |
| temperature | display environment |
| environment | display fan |
| power | display power |
| clock | display clock |
| ntp | display ntp-service status |

The observed OSPF output explicitly says that OSPF is not configured. Empty,
interrupted, duplicated or contradictory output does not establish that state.
The clock fixture exposed a binary floating point conversion that lost one
millisecond; decimal seconds are now converted through Ruby's Rational.

Both `display bgp peer ipv4` and `display alarm active` were rejected on this device.
The [R63xx command index](https://www.h3c.com/cn/Service/Document_Software/Document_Center/Home/Public/00-Public/Command/Command_Manual/H3C_S5130S_EI_D_CR_R63xx-25569/99/)
does not list either command. Other H3C product families support those commands,
so this capture does not justify disabling the generic H3C adapters globally.
Historical log buffer entries are not substituted for active alarms.
