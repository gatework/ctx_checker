# Runtime parser fixtures

These files include small synthetic examples of documented CLI layouts and
sanitized live command bodies. Per-platform source notes distinguish their
origins and verified models. Addresses and identifying names are replaced;
live counters and thresholds may be retained to reproduce observed behavior.
Fixtures do not establish compatibility with every model or firmware version.

Each file represents one command body, without command echo or terminal prompt.
Parser specs also construct malformed, incomplete, contradictory and empty output.
See `vendor/ctx_checker/README.md` for command scope and official references.

Original captures remain in private evidence directories. Source notes for H3C,
NX-OS and Hillstone describe the reduced or sanitized live fixtures and their
remaining coverage limits.
