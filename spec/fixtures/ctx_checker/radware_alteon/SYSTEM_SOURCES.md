# Alteon system fixtures

The `*_5424_32415.txt` system files preserve read-only command bodies captured on
2026-10-16 from an Alteon Application Switch 5424 S Perform running 32.4.15.0.
They contain resource and hardware measurements only. Endpoint, hostname,
serial number, MAC address, prompt, credentials and configuration are excluded.
Negative tests are synthetic mutations, not additional firmware validations.

| Fixture | Verified command |
| --- | --- |
| `mp_cpu_5424_32415.txt` | `/stats/mp/cpu` |
| `mp_memory_5424_32415.txt` | `/stats/mp/mem` |
| `sp_allutils_5424_32415.txt` | `/stats/sp 1/allutils` |
| `temperature_5424_32415.txt` | `/info/sys/temp` |
| `fan_5424_32415.txt` | `/info/sys/fan` |
| `power_5424_32415.txt` | `/info/sys/ps` |

MP and SP utilization remain separate scopes. Physical RAM excludes the
explicit Linux cache; MP process virtual/RSS amounts are recognized source
context, not device utilization. SP CPU windows are 4 and 64 seconds. Each SP
table is checked against its advertised count and average graph. A damaged
memory table does not remove valid CPU readings.

Temperature limits come from `/info/sys/temp`, not a model-wide hard-coded
default or an unrelated command. The captured range starts at 79 C and explicitly
states that 88 C and above is critical. Missing limits stay unknown. Fan failure
severity preserves the stated critical/non-critical distinction. The power
summary describes a single or dual arrangement, not individual supply presence.

Official references:

- [Useful Alteon CLI Commands](https://support.radware.com/app/answers/answer_view/a_id/1010464/~/useful-alteon-cli-commands): `allutils` from 31.0.5 and 32.0 onward, plus version-dependent `allcpu` and `allmem` support.
- [Alteon recommended monitoring OIDs, 34.x](https://support.radware.com/ci/okcsFattach/getFile/16176/Alteon%20Recommended%20OIDs%2034.x%20December%2023.pdf): MP/SP scope and sampling-window definitions.
- [System utilization OID notes](https://support.radware.com/app/answers/answer_view/a_id/1026380/~/a-note-regarding-alteon-system-utilization-oids): MP virtual/RSS trends serve a different purpose from device RAM utilization.
- [OnDemand fan troubleshooting](https://support.radware.com/app/answers/answer_view/a_id/15463/~/ondemand-switches-fan-troubleshooting): operational/failed states and critical/non-critical distinction.
- [Power supply configuration](https://support.radware.com/app/answers/answer_view/a_id/16414): read-only `/info/sys/ps` and the significance of single/dual configuration.
- [Temperature inspection](https://support.radware.com/app/answers/answer_view/a_id/20232/~/ondemand-switch-vl-based-products-ventilation-requirements): `/info/sys/temp` sensor syntax; model-specific limits still require device evidence.
