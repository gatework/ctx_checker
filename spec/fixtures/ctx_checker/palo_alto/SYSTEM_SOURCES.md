# PAN-OS system fixture provenance

All fixtures in this set are synthetic command bodies modeled after the official
formats below. Numeric values, component descriptions, dates and addresses are
test inputs, not device captures or hardware/firmware certification.

- `resources.txt`: [MP resource output](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000ClUbCAK),
  [modern available-memory and legacy cache-adjusted usage](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000POEKCA4).
  Only management-plane utilization is represented. DP CPU/memory remain outside
  this command. Missing available memory in modern output remains unknown.
  Legacy cache-adjusted output preserves physical free memory separately;
  `available_bytes` is total memory minus the adjusted application usage.
- `environmentals.txt`: [environment and hardware status](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000ClW2CAK),
  [device thermal thresholds](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000ClxkCAC),
  [PSU alarm and insertion](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000PMJmCAO).
  Power rails and supplies have separate identities. No supply section does not
  prove PSU coverage. VM-Series hardware sensors may be unsupported.
  These references show thermal Min/Max values and alarm flags, but do not
  establish the comparison at exact equality for every PAN hardware sensor.
  Temperature `high_comparison` therefore remains unspecified; equality at a
  high threshold is unresolved rather than declared healthy.
- `clock.txt`: [show clock layout](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA14u0000004MuZCAU).
  UTC replaces the example's named local zone to test an unambiguous timestamp;
  specs separately assert unresolved local-zone behavior.
- `ntp.txt`: [legacy and modern NTP output](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000ClkXCAS).
  Peer reachability is not proof of system synchronization; LOCAL is a fallback.
- `alarms.txt`: [current hardware and HA alarm state](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000ClW2CAK).
  This command covers current state, not historical system-log events or every
  software/application alarm. Unknown chassis structures stay unresolved.
- `global_counters.txt`: [cumulative counter semantics](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000ClaVCAS),
  [table totals](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA10g000000ClXOCA0).
  Values are cumulative; the CLI's externally shared sampling rate is not used.
  No restart/clear epoch is present, so the parser does not establish continuity.
  The exact `flow_policy_deny` metric is categorized as policy enforcement based
  on [its documented security-policy meaning](https://knowledgebase.paloaltonetworks.com/KCSArticleDetail?id=kA14u000000bqbiCAA).
  Other names are not classified by speculative prefixes; policy counters require
  an explicit metric limit before the evaluator checks their growth.

Sources checked on 2026-10-16. No device connections or counter clears were used.
