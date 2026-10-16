# frozen_string_literal: true

require "digest"
require_relative "parser_registry"
require_relative "observation"
require_relative "observation_merger"
require_relative "parsers/base"
require_relative "failure"

module CtxChecker
  # 离线与实时采集使用同一解析入口，每条命令回显仅解析一次。
  class RuntimeParser
    DIMENSIONS = Observation::NAMES
    MAX_DISCOVERED_QUERIES = 512
    attr_reader :profile, :platform

    # 按请求的平台和型号选择运行解析行为。
    def initialize(platform:, model: nil, software_version: nil)
      @platform = ParserRegistry.canonical(platform)
      @profile = ParserRegistry.fetch(@platform, model: model, software_version: software_version)
      @discovery_observations = {}.freeze
      validate_profile!
    end

    # 通过所选平台与命令策略解析单个运行维度。
    def parse(name, text, complete: false, command: nil)
      parse_many([ name ], text, complete: complete, command: command).fetch(name)
    end

    # 共享命令仅解析一次，再投影各请求维度。
    def parse_many(names, text, complete: false, command: nil)
      self.class.validate_dimensions!(names)
      raise ArgumentError, "CLI output must be text" unless text.is_a?(String)
      raise ArgumentError, "Completeness must be boolean" unless [ true, false ].include?(complete)

      unavailable = names - profile.commands.keys
      if unavailable.any?
        raise ArgumentError, "One output must belong to one supported command" unless unavailable == names

        return names.to_h { |name| [ name, unavailable_observation(name) ] }
      end
      candidates = names.map { |name| profile.commands_for(name) }.reduce(:&)
      command ||= candidates.first if candidates.one?
      raise ArgumentError, "Select one declared command or use parse_outputs for multiple sources" unless candidates.include?(command)
      implementation = profile.parser_for(names.first, command: command)
      command_counts = names.to_h { |name| [ name, profile.commands_for(name).size ] }
      evidence = [ { command: command, sha256: Digest::SHA256.hexdigest(text), bytes: text.bytesize } ]
      source = begin
        normalized = CtxParser::Input.text(text, encoding: :transcode, newlines: :lf, max_bytes: Parsers::Base::MAX_BYTES)
        if /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.match?(normalized)
          raise ArgumentError, "CLI body contains terminal control bytes"
        end
        normalized
      rescue ArgumentError, EncodingError => error
        return names.to_h do |name|
          [ name, Failure.observation(name, code: :invalid_output, stage: :parse, command: command, error: error, evidence: evidence) ]
        end
      end

      result = begin
        implementation.parse(source, complete: complete)
      rescue StandardError => error
        return names.to_h do |name|
          [ name, Failure.observation(name, code: :parser_error, stage: :parse, command: command, error: error, evidence: evidence) ]
        end
      end
      names.to_h do |name|
        [ name, project(name, result, command: command, command_count: command_counts.fetch(name), evidence: evidence) ]
      end
    end

    # 离线调用方逐条提供命令正文，并显式声明完整性。
    def parse_outputs(name, outputs, complete: false)
      self.class.validate_dimensions!([ name ])
      raise ArgumentError, "Completeness must be boolean" unless [ true, false ].include?(complete)
      unless profile.commands.key?(name)
        raise ArgumentError, "Outputs must map declared commands to their bodies" unless outputs.is_a?(Hash) && outputs.empty?
        return unavailable_observation(name)
      end
      unless outputs.is_a?(Hash) && (outputs.keys - profile.commands_for(name)).empty?
        raise ArgumentError, "Outputs must map declared commands to their bodies"
      end
      combine(name, outputs.map { |command, body| parse(name, body, complete: complete, command: command) })
    end

    # 实时采集与离线组装遵循相同的来源及指标覆盖契约。
    def combine(name, observations)
      metrics = name == :counters && profile.respond_to?(:counter_metrics) ? profile.counter_metrics : []
      ObservationMerger.call(name, observations, commands: profile.commands_for(name), required_metrics: metrics)
    end

    # 按命令归组所选维度，避免重复执行共享查询。
    def queries(names)
      self.class.validate_dimensions!(names)
      profile.queries(profile.commands.keys & names)
    end

    # 可选发现依赖仅来自固定平台命令，不递归生成查询。
    def discovery_dimensions(names)
      self.class.validate_dimensions!(names)
      return [] unless profile.respond_to?(:discovery_dimensions)

      dependencies = profile.discovery_dimensions(names)
      unless profile.respond_to?(:expand) && dependencies.is_a?(Array) && dependencies.uniq == dependencies &&
          (dependencies - DIMENSIONS).empty? && (dependencies - profile.commands.keys).empty?
        raise ArgumentError, "Discovery requires unique fixed dimensions and an expansion method"
      end
      dependencies.dup.freeze
    end

    # 扩展有界不可变查询目录前，由平台策略校验来源证据完整性。
    def expand(observations, dimensions:)
      dependencies = discovery_dimensions(dimensions)
      unless observations.is_a?(Hash) && observations.all? { |name, value| value.is_a?(Observation) && value.name == name }
        raise ArgumentError, "Discovery requires named observations"
      end
      return self if dependencies.empty?

      discovered = observations.slice(*dependencies).freeze
      expanded = dup
      expanded.instance_variable_set(:@discovery_observations, discovered)
      candidate = profile.expand(discovered, dimensions: dimensions)
      validate_expansion!(candidate, dimensions)
      expanded.instance_variable_set(:@profile, candidate)
      expanded.send(:validate_profile!)
      expanded
    end

    # 发现不可用时保留实际来源错误及证据，不据此声称硬件不受支持。
    def unavailable_observation(name, discoveries: @discovery_observations, error: nil, code: nil, stage: :discovery)
      dependencies = discovery_dimensions([ name ])
      if dependencies.empty?
        return Observation.new(name: name, status: :unsupported, issues: [ { code: :unsupported_dimension } ])
      end
      sources = discoveries.values_at(*dependencies).compact
      issue = { code: code || (error ? :discovery_expansion_failed : :discovery_unavailable), stage: stage }
      if error
        type = error.class.name
        issue[:error_type] = type.is_a?(String) && Observation::ERROR_TYPE_PATTERN.match?(type) ? type : "StandardError"
      end
      Observation.new(name: name, status: :failed, issues: [ issue, *sources.flat_map(&:issues) ].uniq,
        evidence: sources.flat_map(&:evidence).uniq)
    end

    # 拒绝空、重复或不支持的观测选择。
    def self.validate_dimensions!(names)
      unless names.is_a?(Array) && names.any? && names.uniq == names && (names - DIMENSIONS).empty?
        raise ArgumentError, "Dimensions must be a nonempty unique list of supported symbols"
      end
    end

    private

    # 发现结果仅可在边界内增加请求维度，不能替换已有命令契约。
    def validate_expansion!(candidate, dimensions)
      unless candidate.is_a?(CtxParser::Profile) && candidate.commands.is_a?(Hash)
        raise ArgumentError, "Discovery must return a parser profile"
      end
      added = candidate.commands.keys - profile.commands.keys
      allowed = dimensions.select { |name| discovery_dimensions([ name ]).any? }
      raise ArgumentError, "Discovery added an unrelated dimension" unless (added - allowed).empty?
      profile.commands.each_key do |name|
        unless candidate.commands.key?(name) && candidate.commands_for(name) == profile.commands_for(name) &&
            profile.commands_for(name).all? { |command| candidate.parser_for(name, command: command) == profile.parser_for(name, command: command) }
          raise ArgumentError, "Discovery cannot replace existing commands or parsers"
        end
      end
      original = profile.commands.keys.flat_map { |name| profile.commands_for(name) }.uniq
      if added.any? { |name| (candidate.commands_for(name) & original).any? }
        raise ArgumentError, "Discovery cannot reuse an existing command for a new dimension"
      end
      expanded = candidate.commands.keys.flat_map { |name| candidate.commands_for(name) }.uniq
      raise ArgumentError, "Discovery exceeds the command limit" if (expanded - original).size > MAX_DISCOVERED_QUERIES
    end

    # 目录和型号错误在打开连接器前抛出，不进入运行失败隔离逻辑。
    def validate_profile!
      unless profile.commands.is_a?(Hash) && profile.commands.any? && (profile.commands.keys - DIMENSIONS).empty?
        raise ArgumentError, "Checker profile must declare supported dimensions"
      end
      profile.commands.each_key do |name|
        profile.commands_for(name).each do |command|
          implementation = profile.parser_for(name, command: command)
          unless implementation.is_a?(Class) && implementation < CtxParser::Parser
            raise ArgumentError, "Command parser must inherit from Parser"
          end
        end
      end
    end

    # 单个投影缺失不能使同一回显的其他视图失效。
    def project(name, result, command:, command_count:, evidence:)
      if result.is_a?(CtxParser::ResultSet)
        begin
          result = result.fetch(name)
        rescue StandardError => error
          code = error.is_a?(KeyError) ? :missing_parser_view : :parser_projection_failed
          return Failure.observation(name, code: code, stage: :project, command: command, error: error, evidence: evidence)
        end
      end
      build_observation(name, result, command: command, command_count: command_count, evidence: evidence)
    end

    # 来源状态归属于单个脚本，即使归并维度仅部分完整也独立保留。
    def build_observation(name, result, command:, command_count:, evidence:)
      raise ArgumentError, "Command parser must return a Result or ResultSet" unless result.is_a?(CtxParser::Result)

      status, issues = result.status, result.issues.dup
      # 仅明确的全功能声明可证明不适用；局部空邻居表不能证明。
      inactive = %i[aggregation bgp ospf].include?(name) && result.status == :partial && result.records.empty? && result.issues.any? &&
        result.issues.all? { |issue| %i[protocol_disabled aggregation_not_configured].include?(issue[:code]) }
      inactive ||= name == :aggregation && result.complete? && result.records.empty?
      if inactive && command_count == 1
        issues = [ { code: :aggregation_not_configured } ] if issues.empty?
        return Observation.new(name: name, status: :not_applicable, issues: issues,
          evidence: evidence.map { |entry| entry.merge(status: :complete) })
      end
      issues += [ { code: :incomplete_command_output } ] if status == :partial && issues.empty?
      if command_count > 1
        issues += [ { code: :incomplete_command_set, count: command_count - 1 } ]
        status = :partial if status == :complete
      end
      metadata = { source_complete: result.complete? }
      metadata[:source_command] = command if name == :counters
      defaults = name == :counters ? { unit: :packets, scope: :interface } : {}
      records = result.records.map { |record| defaults.merge(record).merge(metadata) }
      Observation.new(name: name, status: status, records: records, issues: issues,
        covered_scopes: result.is_a?(Parsers::ScopedResult) ? result.covered_scopes : [],
        evidence: evidence.map { |entry| entry.merge(status: result.status) })
    rescue StandardError => error
      Failure.observation(name, code: :invalid_observation, stage: :validate, command: command, error: error, evidence: evidence)
    end
  end
end
