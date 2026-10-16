# PAN-OS interface counter semantics

The CPU counter blocks shown under a physical interface and under its logical
interface are separate processing stages. The current parser selects the
hardware CPU block for physical interfaces (`scope: cpu`) and the logical block
for logical or management interfaces (`scope: logical`); it does not add them.

`receive errors` maps to `in_errors`, `transmit errors` to `out_errors`, explicit
`receive discarded`/`receive packets dropped` to `in_discards`, and `transmit
packets dropped` to `out_discards`. These reported values use packet units.
CPU receive errors concern L2-L4 parsing/header checks and do not establish a
MAC CRC measurement. `receive incoming errors` is a separate MAC-mismatch/FIFO
overrun counter, not an alias of `receive errors`.
Reference: [Difference between receive errors and receive incoming errors](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA14u0000004Le6CAE).

The unqualified `packets dropped` counter is not currently projected into the
directional discard metric. Hardware and logical drops have different causes;
logical drops may be expected preprocessing behavior. Neither is summed into
`receive discarded`, and neither may be presented as a physical-link failure
without additional evidence. A future adaptation must preserve both processing
stages as distinct facts.
Reference: [Logical interface packet drop counter explanation](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA14u0000008V0lCAE).
