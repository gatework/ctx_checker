# H3C interface fixtures

`interfaces_s5130s.txt` and `aggregation_s5130s.txt` are reduced from read-only
`display interface` and `display link-aggregation verbose` captures collected on
2026-10-16 from an H3C S5130S-52S-EI. They preserve the observed column layout,
wrapped VLAN metadata, internal interface fields and reference-port marker.

Device names, addresses and operational descriptions were removed. Interface
numbers, aggregation IDs, VLAN values, traffic values and the remote system MAC
were replaced with synthetic examples. These files are regression fixtures, not
complete device captures or a claim of support for every Comware release.

The directional `display counters inbound interface` and
`display counters outbound interface` captures matched the existing counter-table
grammar. Physical discard counts were absent from these captures; the fixtures
must not imply that missing measurements equal zero.

The same interface capture includes directional `Input: ... packets, ... bytes,
... drops` and `Output: ... packets, ... bytes, ... drops` for the internal
InLoopBack and NULL interfaces. Only the explicit drop field becomes
`in_discards` or `out_discards`; packet and byte totals are ignored. Tests vary
these values and inject malformed, repeated and description-only text. Those
mutations verify parsing boundaries and are not additional device captures.
