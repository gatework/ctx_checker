# ctx_checker

[简体中文](README-zh.md) | [Source](https://github.com/gatework/ctx_checker) | [Changelog](CHANGELOG.md)

Runtime health analysis for heterogeneous network devices. Vendor parsers normalize observed metrics; policies evaluate those facts without treating missing evidence as healthy.

## Features

- Interfaces, normalized error/discard counters, aggregation members, optics, BGP, and OSPF.
- CPU, memory, temperature, environment, power, clock, NTP, active alarms, and device counters.
- Profiles for H3C, Cisco IOS/IOS-XE, Cisco NX-OS, Palo Alto, Hillstone, and Radware Alteon; coverage differs by platform.
- Independent command execution and parsing, explicit applicability, and optional comparison with a prior sample.

## Installation

Requires **Ruby 4.0.6 or newer**. Add this line to your application's `Gemfile`:

```ruby
gem "ctx_checker"
```

Then run `bundle install`, or install directly with `gem install ctx_checker`. The require path is `ctx_checker` and the public namespace is `CtxChecker`; package names and Ruby namespaces are intentionally separate.

Internal runtime dependencies: [`ctx_parser`](https://github.com/gatework/ctx_parser), [`ctx_driver`](https://github.com/gatework/ctx_driver). The gemspec declares runtime dependencies without version constraints. Applications should commit their own `Gemfile.lock` to make deployments reproducible. No Rails boot or sibling checkout paths are required.

Release artifacts and checksums are available from [GitHub Releases](https://github.com/gatework/ctx_checker/releases). Check [RubyGems](https://rubygems.org/gems/ctx_checker) for published versions.

## Offline example

From a development checkout after installing dependencies:

```sh
bundle exec ruby examples/offline.rb
```

The example uses synthetic data and performs no network access:

```ruby
require "ctx_checker"

# 使用合成的 IOS 命令回显，本例不连接设备。
output = "GigabitEthernet1/0/1 is up, line protocol is up\n"
parser = CtxChecker::RuntimeParser.new(platform: :cisco_ios)
observation = parser.parse(:interfaces, output, complete: true)
snapshot = CtxChecker::Snapshot.new(
  target: { host: "192.0.2.10", platform: parser.platform },
  observed_at: Time.utc(2026, 1, 1),
  observations: { interfaces: observation }
)
policy = CtxChecker::Policy.new(required_interfaces: [ "GigabitEthernet1/0/1" ])
report = CtxChecker::Evaluator.new(policy: policy).call(snapshot)
puts report.to_text
# 未请求的维度保持 not_requested，本例不代表整机检查。
```

## Public contract and limits

`RuntimeParser.new(platform:, model: nil, software_version: nil)` exposes `parse`, `parse_many`, and `parse_outputs`. Build `Snapshot` from observations and evaluate it with `Evaluator.new(policy: Policy.new).call(snapshot, previous: nil)`. Reports expose `to_text`, `to_h`, `summary`, and coverage.

Observation completeness (`complete`, `partial`, `failed`, `unsupported`, `not_requested`, `not_applicable`) is separate from findings (`pass`, `fail`, `unknown`, `not_applicable`). Empty output alone cannot prove a healthy or unconfigured feature. Confirmed configuration can establish that optional BGP, OSPF, or aggregation checks do not apply; required policy still takes precedence.

Errors, CRC, and discards are distinct counters and must not be summed. A single cumulative value is not a current error rate. Delta analysis needs matching identities, increasing timestamps, and reliable continuity evidence. Optics need device or policy thresholds; supported command formats do not guarantee every model/version is covered.

`Collector#collect` accepts an injected connector that owns its session lifecycle; `collect_session` borrows an existing session. No Rails, inventory database, scheduler, or credentials are included. See the [counter contract](COUNTER_CONTRACT.md) for metric semantics.

Detailed vendor behavior, historical validation notes, and Motor-only integration are preserved in [the architecture reference](docs/architecture-zh.md). Host integration examples in that reference require Motor; they are not standalone gem APIs. Motor adapters live under `backend/lib/baseline`, `backend/lib/vxlan`, and `backend/lib/wireless` in the [Motor repository](https://github.com/gatework/motor/tree/main/backend/lib).

The lifecycle connector is a host adapter exposing `open { |session| }` (and `platform` for VXLAN and Wireless). It is distinct from a native `Net::Connector::Base` device instance. Borrowed native sessions are accepted by `CtxDriver::Reader` and `CtxChecker::Collector#collect_session`; they are never implicitly connected or retried.

## Domain vocabulary

An `Observation` describes collected evidence for a dimension; a `Finding` describes its health assessment. `Policy#required_dimension?` and `SystemPolicy#required_dimension?` query required observation dimensions. Interface and optical requirements retain their scoped identity checks. Counter limits compare increments over a validated sampling interval in seconds; they are not cumulative totals or rates.

Integer OSPF process IDs are normalized to strings in policies, observations, and covered scopes before checking identities. An explicit temperature threshold requires a numeric reading; an `ok` sensor state alone cannot satisfy it. Parsers retain at most 128 diagnostic samples per result, plus a `diagnostics_truncated` entry counting omitted diagnostics; truncation never proves complete evidence.

## Development and tests

Name shared classes by their responsibility and use the namespace for platform context. Preserve filenames and class names that directly match device commands.

```sh
bundle install
bundle exec rake
bundle exec ruby examples/offline.rb
bundle exec rake build
```

`bundle exec rake` runs RSpec, RuboCop, and the offline examples. Tests live in `spec/`, following the existing project's RSpec convention; fixtures use synthetic or sanitized evidence. Add regression cases for successful, incomplete, unsupported, and malformed inputs when extending a parser. Offline tests do not certify all device versions or replace live integration checks.

Run `ruby script/verify_package.rb /path/to/ctx_checker.gem` to verify an isolated installation with published dependencies. During coordinated development, append explicitly built dependency artifacts, such as `/path/to/ctx_parser.gem`, to install those candidates first. Candidate verification does not establish that the published dependencies are compatible. `bundle exec ruby -Ilib benchmark/runtime.rb` measures synthetic command lookup and diagnostic overhead locally.

Use the declared minimum Ruby version for compatibility checks. Document source methods and non-obvious business logic in concise Chinese, preserve public return/error contracts, and never add raw device captures or credentials to examples, fixtures, logs, or release archives.

## Release

This directory can be maintained as the independent [ctx_checker](https://github.com/gatework/ctx_checker) repository. Update `VERSION` and `CHANGELOG.md`, run the validation and build commands above, and inspect the packaged file list before tagging `vVERSION`.

CI runs tests, lint, examples, build, and an isolated installation on Linux and macOS. After CI passes on `main`, push `vVERSION` to run the release workflow. It publishes the tested Linux artifact to RubyGems and GitHub Releases, attaches `SHA256SUMS`, and verifies downloaded bytes. The GitHub `release` environment accepts a `RUBYGEMS_API_KEY` secret; without it, configure RubyGems Trusted Publishing for this repository, `release.yml`, and the `release` environment. Retry a failed publish job to reuse its CI artifact; an already published version must have identical bytes. See [release details](docs/release.md).

Publish dependency gems first. A Git tag, a successful build, or a workflow file does not establish that the gem has reached RubyGems; confirm the registry result separately. See [CHANGELOG.md](CHANGELOG.md) for release notes.

## License

MIT. See [LICENSE](LICENSE).
