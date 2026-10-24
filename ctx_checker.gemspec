# frozen_string_literal: true

require_relative "lib/ctx_checker/version"

Gem::Specification.new do |spec|
  spec.name = "ctx_checker"
  spec.version = CtxChecker::VERSION
  spec.authors = [ "Gatework contributors" ]
  spec.summary = "Analyze multi-vendor network runtime health."
  spec.description = "Normalize interfaces, routing protocols, optical metrics, system resources and counters into evidence-aware health reports."
  spec.homepage = "https://github.com/gatework/ctx_checker"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.6"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "documentation_uri" => "#{spec.homepage}#readme",
    "allowed_push_host" => "https://rubygems.org",
    "rubygems_mfa_required" => "true"
  }
  # 显式限定打包文件，排除设备回显、凭据、测试夹具和构建产物。
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "examples/**/*.rb", "docs/**/*.md", "README*.md", "CHANGELOG.md", "LICENSE", "COUNTER_CONTRACT.md"].sort }
  spec.require_paths = [ "lib" ]

  spec.add_dependency "ctx_runner"
  spec.add_dependency "ctx_parser"
  spec.add_dependency "ctx_driver"
  spec.add_dependency "date"
  spec.add_dependency "digest"
  spec.add_dependency "ipaddr"
  spec.add_dependency "json"
  spec.add_dependency "time"
end
