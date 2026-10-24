# Interface Counter Semantics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove implicit packet semantics for observations whose measurement unit or scope is absent.

**Architecture:** Observation retains missing evidence. Counters requires explicit packet semantics before assessing cumulative values or deltas. Declared runtime command semantics and independent device counters retain their existing responsibilities.

**Tech Stack:** Ruby, RSpec, RuboCop, RubyGems, Bundler.

**Spec:** `docs/superpowers/specs/2026-10-24-counter-semantics.md`

## Global Constraints

- Ruby >= 4.0.6；项目 Bundler 与当前依赖政策保持不变。
- lib 方法注释中文，业务字面量英文；不批量翻译测试及文档。
- 不改厂商 CLI 文件/类/目录，不新增厂商支持或推测设备语义。
- 保留所有既有 WIP；未授权提交、推送或发布。
- 本地合成及安装证据不代表所有依赖版本、设备型号、平台或远端 CI。

## Review Focus

- Missing and explicit nil semantics must never certify zero cumulative values.
- Two equally incomplete samples must not compute a packet delta.
- Known current samples cannot use previous samples with missing/different semantics.
- Device-level counters must retain their distinct policy.
- Packet delta tests must retain continuity/time/source completeness coverage after their inputs declare units and scope.

### Task 1: Make unknown measurement semantics unconditionally unknown

**Files:**
- Modify: `lib/ctx_checker/checks/counters.rb`
- Modify: `spec/counter_semantics_spec.rb`
- Modify: `spec/evaluator_spec.rb`
- Modify: `spec/source_independence_spec.rb`
- Modify: `spec/multi_command_spec.rb`
- Modify: `COUNTER_CONTRACT.md`, `CHANGELOG.md`
- Create: this plan and its spec.

**Interfaces:**
- Consumes: `Observation` counters with `unit`, `scope`, `value`, `discontinuity` and sample/source evidence.
- Produces: existing Evaluator findings; `counter_unit_unknown` / `counter_scope_unknown` for missing current semantics, existing changed-semantics reasons for incompatible prior samples. No public method signature change.

- [x] **Step 1:** Update existing semantics tests. Missing keys and explicit nil, current values 0/2, with/without equally incomplete prior samples must all return unknown with no delta. Preserve tests for known scope, changed prior semantics, declared runtime defaults and device counters.
- [x] **Step 2:** Run `bundle exec rspec spec/counter_semantics_spec.rb`; expect failure because missing semantics currently pass or compute delta. Record the failing output.
- [x] **Step 3:** Make `packet_semantics_reason(record, prior)` classify missing/nil units and scopes as unknown before packet threshold evaluation. Remove the nil-as-packets branch. No new abstraction.
- [x] **Step 4:** Give existing packet fixtures in evaluator/source_independence/multi_command specs explicit packets/interface fields; keep all original behavioral assertions. Update contract and Changelog to remove the old API exemption.
- [x] **Step 5:** Run targeted specs, `bundle exec rake`, explicit `bundle exec rubocop lib spec examples script Gemfile Rakefile ctx_checker.gemspec`; expect all passing. Review the diff and preserve the completed change without committing.
- [x] **Step 6:** Obtain one fresh independent review and resolve substantive findings with a single RED/GREEN fix pass. Guard-copy changed files into the actual checkout and run its ordinary `bundle exec rake`. Build current selected candidates and verify installed behavior without source-path injection, exact metadata and bytes. Record SHA256 and evidence limits.
