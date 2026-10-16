# frozen_string_literal: true

require_relative "ctx_checker/version"

module CtxChecker
  # 独立运行时由 Ruby 管理延迟加载，同时保留 Zeitwerk 已有注册。
  {
    Observation: "observation", Snapshot: "snapshot", Policy: "policy", Finding: "finding",
    Report: "report", Evaluator: "evaluator", RuntimeParser: "runtime_parser", Collector: "collector", Applicability: "applicability",
    SystemPolicy: "system_policy", SystemRecord: "system_record", ObservationMerger: "observation_merger", Failure: "failure",
    ParserRegistry: "parser_registry", Parsers: "parsers/base", H3c: "h3c/profile",
    CiscoIos: "cisco_ios/profile", CiscoNxos: "cisco_nxos/profile", PaloAlto: "palo_alto/profile",
    Hillstone: "hillstone/profile", RadwareAlteon: "radware_alteon"
  }.each do |name, path|
    autoload(name, File.expand_path("ctx_checker/#{path}", __dir__)) unless const_defined?(name, false)
  end
end
