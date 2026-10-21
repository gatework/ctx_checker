# Changelog

Changes to the public contract are recorded here. Versions follow Semantic Versioning.

## 0.3.0 (2026-10-22)

- Delegate shared collection, evidence and execution contracts to ctx_runner.
- Preserve domain parsing, change policies, CLI layouts and connection ownership.

## Unreleased

## 0.2.5 (2026-10-21)

- Snapshot entire offline command/body batches before parser callbacks and reject non-text bodies before invoking any parser.
- Reduce temporary field-pair allocations when normalizing observations; add a configuration-to-report benchmark with semantic assertions.

- Add repository-specific AGENTS.md guidance for responsibilities, Ruby conventions, evidence boundaries and validation.
- Snapshot offline runtime view selections and explicit commands before parser callbacks, preserving result projections and evidence attribution.

## 0.2.4 (2026-10-19)

- Parse whitespace-delimited IOS, NX-OS, H3C and PAN-OS facts independently of Ruby's global field separator, preserving native whitespace splitting semantics.
- Exercise the five-gem collection-to-report chain with a local PTY in default checks and isolated package validation, including shared queries, source digests and command rejection without reconnecting.
- Activate explicitly supplied candidate package versions exactly during isolated verification; incompatible candidates fail instead of silently testing a newer dependency.
- Correct dependency documentation to match the existing compatible 0.2.x constraints.

## 0.2.3 (2026-10-18)

- Clear Bundler bootstrap variables when verifying packages in an isolated gem installation, including calls made through bundle exec.

- Index protocol coverage and conflicting scopes by field sets, preserving wildcard identities and OSPF interface scopes without quadratic scans.

## 0.2.2 (2026-10-18)

- Snapshot validated collection targets and dimensions before caller callbacks can alter them.
- Require lifecycle connectors to provide exactly one session, preventing silent empty collections and repeated queries.
- Reject unrequested observations as command fragments rather than upgrading them to complete evidence.

- Exercise the current optional net-connector API and share protocol receipts across custom-session tests without tying generic fixtures to connector result internals.

- Preserve proven aggregation capacity lower bounds in partial observations while retaining unknown overall coverage.
- Parse vendor lines and reconstruct H3C counters independently of Ruby's global record and output separators.
- Require valid dates and explicit UTC offsets in snapshot and command evidence timestamps, consistent with record timestamps.
- Count only complete member sources when proving aggregation capacity; incomplete sources cannot prove a capacity shortage.
- Index command diagnostics once per observation when constructing reports, avoiding repeated scans for expanded port queries.
- Add a synthetic report construction benchmark for 64, 256, and 512 failed queries.

## 0.2.1 (2026-10-17)

- Validate time-limit snapshot compatibility during policy construction; reject unsupported Numeric objects before evaluation while preserving exact Rational values.

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
