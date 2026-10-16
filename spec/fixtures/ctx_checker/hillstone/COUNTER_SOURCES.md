# StoneOS CPU port counter fixture

`cpu_cntr_a3700_55r10p14.txt` is the body of read-only `show cpu-cntr`, collected
on 2026-10-16 from SG-6000-A3700 / SG6000-A-1-5.5R10P14. Device endpoint, identity,
prompt and credentials are excluded. Only vendor-native component names remain.

The initial `cpu Port Send Rev Counter` traffic summary contains joined numeric
cells. It is recognized as context and deliberately contributes no records.
The independently named MGT0, HA0 and internal-port blocks supply labelled
hardware counters and explicitly headed RX/TX queues. Port and queue totals
are never summed, and no reset epoch or sampling interval is inferred.

Only fields explicitly describing bad octets, bad packets, receive errors,
CRC/alignment errors and queue errors are classified as errors. Good traffic
and packet-size distributions are informational. Other collision, fragment,
oversize and drop fields retain `unknown` categories until their exact StoneOS
semantics are documented; names alone do not establish device faults or
policy enforcement. Synthetic mutations in the spec cover invalid or missing
values, future fields, duplicated identities and incomplete queues.

The real `internal0/28` InBadPkts value is a cumulative 922. This provides a
historical warning, not proof of a current error rate or a device failure.
