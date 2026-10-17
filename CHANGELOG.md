# Changelog

Changes to the public contract are recorded here. Versions follow Semantic Versioning.

## 0.2.0 (2026-10-17)

- Require ctx_parser and ctx_driver 0.2.x for the renamed public contracts.

- Allow isolated package verification to install explicitly supplied dependency candidate artifacts without changing gemspec dependency constraints.
- Require a measured temperature when an exact sensor policy supplies numeric thresholds.
- Preserve conflicting Cisco interface states as incomplete evidence and retain observed protocol failures.
- Normalize integer OSPF process identities in policies, observations, and coverage scopes; reject normalized duplicates.
- Bound parser diagnostic samples to 128 plus an omitted-count summary, and skip vendor parsing for explicit command failures.
- Index validated command implementations for response parsing, rebuilding the index after discovery expansion.

- Use the shared `CtxParser::Configuration`, `Results`, and `Commands` names and dimension indexes where applicable.

- Name system field definitions and validation `SystemFields`; exercise installed BGP parsing during package verification.

- Rename domain APIs directly; callers must use the new names (no compatibility aliases).

- Name required-dimension predicates and policy validators explicitly; expose sampling interval units in counter evaluation.

### Changed

- Index CPU windows, optical measurements, aggregation membership, and required interfaces once, avoiding repeated full scans during parsing and health evaluation.

## 0.1.0 (2026-10-16)

### Added

- Multi-vendor observations, normalized counters, applicability, runtime policies, and health reports.
- Standalone RubyGems packaging under `ctx_checker` with the `ctx_checker` require path and `CtxChecker` namespace.
- English and Chinese documentation, an offline example, and standalone RSpec/RuboCop development tasks.
- Linux/macOS CI, isolated package verification, and automatic RubyGems and GitHub Releases with identical artifacts.

### Changed

- Cross-module dependencies resolve through RubyGems/Bundler instead of relative sibling paths.
- Motor persistence and application-specific adapters remain in the host application.
