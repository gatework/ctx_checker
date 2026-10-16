# frozen_string_literal: true

require "time"
require "ctx_driver"
require_relative "runtime_parser"
require_relative "snapshot"
require_relative "failure"
require_relative "applicability"

module CtxChecker
  # 按声明目录顺序查询设备，并明确连接资源的归属。
  class Collector
    DEFAULT_DIMENSIONS = RuntimeParser::DIMENSIONS

    # 注入为顺序命令观测生成时间戳的时钟。
    def initialize(clock: -> { Time.now.utc })
      @clock = clock
    end

    # 连接的建立与清理由传入连接器的块生命周期管理。
    def collect(target:, connector:, dimensions: DEFAULT_DIMENSIONS, applicability: nil)
      parser, identity = prepare(target, dimensions)
      if connector.respond_to?(:platform) && ParserRegistry.canonical(connector.platform) != parser.platform
        raise ArgumentError, "Connector platform differs from the target"
      end
      observations = inapplicable_observations(parser, dimensions, applicability)
      dimensions = dimensions - observations.keys
      return Snapshot.new(target: identity, observed_at: @clock.call, observations: observations) if dimensions.empty?

      issues = []
      stage = :connect
      begin
        connector.open do |session|
          stage = :collect
          collect_into(session, parser, dimensions, observations)
          stage = :close
        end
      rescue StandardError => error
        raise unless CtxDriver::Failure.connection_error?(error, connector)

        code = stage == :close ? :session_close_failed : CtxDriver::Failure.code(error, :connection_failed)
        issues << { code: code, stage: stage }
        mark_unavailable(parser, dimensions, observations, code: code, stage: stage, error: error)
      end
      reconcile_applicability(observations, applicability)
      Snapshot.new(target: identity, observed_at: @clock.call, observations: observations, issues: issues)
    end

    # 借用已打开的 net-connector 会话，不负责建立或关闭连接。
    def collect_session(target:, session:, dimensions: DEFAULT_DIMENSIONS, applicability: nil)
      parser, identity = prepare(target, dimensions)
      observations = inapplicable_observations(parser, dimensions, applicability)
      dimensions = dimensions - observations.keys
      collect_into(session, parser, dimensions, observations) if dimensions.any?
      reconcile_applicability(observations, applicability)
      Snapshot.new(target: identity, observed_at: @clock.call, observations: observations)
    end

    private

    # 配置证据可排除未启用的可选功能，但不改变未知运行证据的状态。
    def inapplicable_observations(parser, dimensions, applicability)
      return {} unless applicability
      unless applicability.is_a?(Applicability) && applicability.platform == parser.platform
        raise ArgumentError, "Applicability must belong to the target platform"
      end

      dimensions.select { |name| applicability.not_applicable?(name) }.to_h do |name|
        [ name, Observation.new(name: name, status: :not_applicable,
          issues: [ { code: :feature_not_configured } ], evidence: applicability.evidence) ]
      end
    end

    # 已配置功能与运行回显禁用相互矛盾，两者不能静默覆盖。
    def reconcile_applicability(observations, applicability)
      return unless applicability

      observations.each do |name, observation|
        next unless observation.status == :not_applicable && applicability.state(name) == :configured

        observations[name] = Observation.new(name: name, status: :partial,
          issues: [ *observation.issues, { code: :configuration_runtime_conflict } ],
          evidence: observation.evidence + applicability.evidence)
      end
    end

    # 发送任何设备命令前，先校验维度选择与目标身份。
    def prepare(target, dimensions)
      RuntimeParser.validate_dimensions!(dimensions)
      raise ArgumentError, "Target must be a hash" unless target.is_a?(Hash)

      parser = RuntimeParser.new(platform: target.fetch(:platform), model: target[:model], software_version: target[:software_version])
      parser.discovery_dimensions(dimensions)
      # 打开连接器前校验身份，避免将输入错误误报为连接故障。
      snapshot = Snapshot.new(target: target.merge(platform: parser.platform), observed_at: @clock.call, observations: {})
      [ parser, snapshot.target ]
    end

    # 采集发现命令及其依赖命令，保留各自独立的失败结果。
    def collect_into(session, parser, dimensions, observations)
      reader = CtxDriver::Reader.new(session: session, clock: @clock)
      fragments = Hash.new { |hash, key| hash[key] = [] }
      dependencies = parser.discovery_dimensions(dimensions)
      dependency_commands = dependencies.empty? ? [] : parser.queries(dependencies).keys
      discovery_queries = parser.queries((dimensions + dependencies).uniq).select { |command, _names| dependency_commands.include?(command) }
      collect_queries(reader, parser, discovery_queries, fragments)
      discoveries = dependencies.to_h { |name| [ name, parser.combine(name, fragments.fetch(name)) ] }
      begin
        parser = parser.expand(discoveries, dimensions: dimensions)
      rescue StandardError => error
        expansion_error = error
      end
      queries = parser.queries(dimensions).reject { |command, _names| discovery_queries.key?(command) }
      collect_queries(reader, parser, queries, fragments)
      dimensions.each do |name|
        observations[name] = if parser.profile.commands.key?(name)
          parser.combine(name, fragments.fetch(name))
        else
          parser.unavailable_observation(name, discoveries: discoveries, error: expansion_error)
        end
      end
    end

    # 发现阶段与扩展采集阶段共用单条顺序命令边界。
    def collect_queries(reader, parser, queries, fragments)
      queries.each do |command, names|
        read(reader, parser, command, names).each { |name, observation| fragments[name] << observation }
      end
    end

    # 每条命令独立承担失败；单个脚本失败不能丢弃此前事实。
    def read(reader, parser, command, names)
      capture = reader.read(command)
      evidence = capture.evidence
      unless capture.success?
        return names.to_h do |name|
          [ name, Failure.observation(name, **capture.failure, command: command, evidence: evidence, skipped: capture.skipped?) ]
        end
      end

      begin
        parser.parse_many(names, capture.body, complete: true, command: command).transform_values do |observation|
          records = if %i[counters device_counters].include?(observation.name)
            observation.records.map { |record| record.merge(sampled_at: evidence.first[:observed_at]) }
          else
            observation.records
          end
          source_status = observation.evidence.first&.fetch(:status, nil) || observation.status
          Observation.new(name: observation.name, status: observation.status, records: records,
            covered_scopes: observation.covered_scopes,
            issues: observation.issues, evidence: evidence.map { |entry| entry.merge(status: source_status) })
        end
      rescue StandardError => error
        failure = CtxDriver::Failure.details(error, fallback: :command_processing_failed, stage: :parse)
        names.to_h { |name| [ name, Failure.observation(name, **failure, command: command, evidence: evidence) ] }
      end
    end

    # 连接建立失败时仍标明各条计划查询，不覆盖已完成事实。
    def mark_unavailable(parser, dimensions, observations, **failure)
      dimensions.each do |name|
        next if observations.key?(name)

        observations[name] = if parser.profile.commands.key?(name)
          sources = parser.profile.commands_for(name).map do |command|
            Failure.observation(name, **failure, command: command, skipped: true)
          end
          parser.combine(name, sources)
        else
          parser.unavailable_observation(name, error: failure[:error], code: failure[:code], stage: failure[:stage])
        end
      end
    end
  end
end
