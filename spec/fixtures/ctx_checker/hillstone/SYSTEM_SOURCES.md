# StoneOS system fixtures

`cpu_a3700_55r10p14.txt`, `memory_a3700_55r10p14.txt`, and
`environment_a3700_55r10p14.txt` preserve the grammar of read-only `show cpu`,
`show memory`, and `show environment` captures collected on 2026-10-16 from a
Hillstone SG-6000-A3700 running SG6000-A-1-5.5R10P14. The command bodies contain
resource and hardware readings only; device identity, endpoint, prompt and
connection credentials are excluded. Negative cases in the spec are synthetic
mutations of those captures, not additional verified firmware variants.

The current memory summary is integer-truncated while its total/used/free row
and historical graphs use different precision and periods. Only checked current
totals contribute current usage. The CPU `Average` line does not identify its
sampling period. The temperature `Range` does not state threshold equality
semantics. Neither omission is inferred by the parser.

Official command references used to confirm read-only hardware inspection:

- [Hillstone X-Series Hardware Reference Guide](https://kb.hillstonenet.com/en/wp-content/uploads/2015/06/Hillstone_SG-6000_X-Series_Hardware_Reference_Guide.pdf), cooling-system troubleshooting: `show environment`.
- [StoneOS 5.5R10F6 Release Note](https://www.hillstonenet.com/wp-content/uploads/StoneOS-5.5R10F6-Release-Note.pdf), ID 41747: model-specific additions to `show environment power` and `show environment fan`. Those narrower commands returned no measurements on the captured A3700 and are not used as the inspection source.
