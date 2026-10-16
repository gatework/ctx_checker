# H3C system fixtures

These are **synthetic** offline examples, composed from documented CLI grammar with invented measurements, timestamps and documentation addresses. They are not device captures or model certification. Each file represents one command body; no live devices were contacted.

| Files | Command | Official grammar reference |
| --- | --- | --- |
| cpu, memory, clock | display cpu-usage / display memory / display clock | [S6805/S6825/S6850/S9850 R6715 device management](https://www.h3c.com/en/Support/Resource_Center/EN/Home/Public/00-Public/Technical_Documents/Reference_Guides/Command_References/H3C_S6805_S9850_CRs_Release_6715-18388/01/202404/2101654_294551_0.htm) |
| temperature, environment | display environment / display fan | [Hardware resource grammar](https://www.h3c.com/en/d_202001/1262021_294551_0.htm) and [fan block variant](https://knowledge.h3c.com/Theme/details/192373) |
| power | display power | [Power supply table and state definitions](https://www.h3c.com/en/d_202302/1765208_294551_0.htm) |
| ntp | display ntp-service status | [Current system peer/reference semantics](https://www.h3c.com/en/Support/Resource_Center/EN/Home/Public/00-Public/Technical_Documents/Reference_Guides/Command_References/H3C_CR-35328/03/202609/2929699_294551_0.htm) and [older clock-offset field](https://www.h3c.com/en/d_201905/1177747_294551_0.htm) |
| alarms | display alarm active | [Active alarm table/severity](https://www.h3c.com/en/d_202605/2842414_294551_0.htm) |
| counters_inbound, counters_outbound | display counters inbound interface / display counters outbound interface | [Comware directional counter grammar](https://www.h3c.com/en/d_201905/1175488_294551_0.htm) and [switch command reference](https://wwwsg.h3c.com/cn/d_202308/1904853_30005_0.htm) |

Memory usage uses the physical pool's cache-adjusted application row only after checking the Used/Free adjustment against the same pool's raw Used/Free/Buffers/Cached values. Normalized used_bytes represents cache-adjusted application use, free_bytes retains raw physical free memory, and available_bytes represents cache-adjusted availability. Container free_bytes is omitted because its displayed Free belongs to the host physical pool. Without this evidence, raw Used/Total remains explicitly used_including_cache; FreeRatio is never treated as usage. Container and swap pools are not silently mixed with physical memory.

Temperature uses per-sensor device thresholds. Lower/LowerLimit maps to low_warning: the [Comware TEMPERATURE_LOW event has severity 4](https://www.h3c.com/en/Support/Resource_Center/EN/Switches/Catalog/S6890/S6890/Technical_Documents/Reference_Guides/Log_Message_References/H3C_S6890_Log_R28xx/), matching a warning rather than the higher-severity overtemperature alarm. Power and fan absence remain population evidence rather than assumed failure.

NTP jitter is not silently substituted for offset. The optional local-clock sync field accepts only an explicit clock-synced state; unknown or duplicate states retain incomplete evidence. H3C high temperature limits use inclusive comparisons (high_comparison=gte), matching the documented reaches-threshold behavior; low temperature uses a strict below comparison. Clock timestamps with unresolved named zones or daylight saving rules remain unknown.

Directional interface counters retain only the documented Err column as in_errors/out_errors. Total/Broadcast/Multicast packets are traffic context, not CRC or discards; Overflow and -- stay unavailable. No source establishes counter continuity. H3C device_counters is unsupported: interface records are not summed into fabricated global metrics.

Active-alarm messages are deliberately excluded from normalized records; only IDs and severity are retained. No-empty-alarm response is a synthetic negative/empty boundary, not a claim that all H3C releases print that wording.
