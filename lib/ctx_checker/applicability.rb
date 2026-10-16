# frozen_string_literal: true

require "digest"
require "ctx_parser/document"
require "ctx_parser/banner"
require "ctx_parser/immutable"
require_relative "parser_registry"

module CtxChecker
  # 配置证据可证明功能存在或缺失；运行回显为空不能证明任何一者。
  class Applicability
    DIMENSIONS = %i[aggregation bgp ospf].freeze
    MAX_BYTES = 16 * 1024 * 1024
    SUPPORTED_PLATFORMS = %w[h3c cisco_ios cisco_nxos].freeze
    ROOT_PATTERNS = {
      h3c: {
        aggregation: /\A(?:interface\s+(?:Bridge-Aggregation|Route-Aggregation)\s*\d|link-aggregation\s+group\b)/i,
        bgp: /\Abgp\b/i, ospf: /\Aospf(?:v3)?\b/i
      },
      cisco: {
        aggregation: /\Ainterface\s+(?:Port-channel|Bundle-Ether)\s*\d/i,
        bgp: /\Arouter\s+bgp\b/i, ospf: /\A(?:router\s+ospf(?:v3)?|ipv6\s+router\s+ospf)\b/i
      }
    }.transform_values { |patterns| patterns.transform_values(&:freeze).freeze }.freeze
    INTERFACE_PATTERNS = {
      h3c: { aggregation: /\A(?:port\s+link-aggregation\s+group|link-aggregation)\b/i,
        ospf: /\A(?:ip\s+)?ospf(?:v3)?\b/i },
      cisco: { aggregation: /\Achannel-group\b/i,
        ospf: /\A(?:(?:ip|ipv6)\s+(?:router\s+)?ospf|ospfv3)\b/i }
    }.transform_values { |patterns| patterns.transform_values(&:freeze).freeze }.freeze
    VRF = /\A(?:vrf\s+(?:definition|context)\s+|ip\s+(?:vrf|vpn-instance)\s+)/i
    ADDRESS_FAMILY = /\A(?:address-family|ipv[46]-family)\b/i
    HINTS = { aggregation: /\b(?:link-aggregation|bridge-aggregation|route-aggregation|channel-group|port-channel|bundle-ether|lacp)\b/i,
      bgp: /\bbgp\b/i, ospf: /\bospf(?:v3|6)?\b/i }.freeze

    attr_reader :platform, :evidence

    # 仅使用可追溯的配置证据推断可选功能是否适用。
    def self.from_configuration(platform:, text:, complete: false, reference: nil)
      new(platform: platform, text: text, complete: complete, reference: reference)
    end

    # 冻结配置推导的可选功能状态及其证据。
    def initialize(platform:, text:, complete:, reference: nil)
      raise ArgumentError, "Configuration must be text" unless text.is_a?(String)
      raise ArgumentError, "Completeness must be boolean" unless [ true, false ].include?(complete)
      unless (platform.is_a?(String) || platform.is_a?(Symbol)) && !platform.to_s.strip.empty? && !/[\x00-\x1f\x7f]/.match?(platform.to_s)
        raise ArgumentError, "Platform must be text"
      end
      unless reference.nil? || reference.is_a?(String) && !reference.strip.empty? && !/[\x00-\x1f\x7f]/.match?(reference)
        raise ArgumentError, "Configuration reference must be text"
      end

      @platform = canonical_platform(platform).freeze
      source = { sha256: Digest::SHA256.hexdigest(text), bytes: text.bytesize }
      source[:reference] = reference unless reference.nil?
      @evidence = CtxParser::Immutable.copy([ source ])
      @states = CtxParser::Immutable.copy(configuration_states(text, complete: complete))
      freeze
    end

    # 返回功能已配置、未配置或未知的证据状态。
    def state(name) = @states.fetch(name, :unknown)
    # 检查证据是否明确证明可选功能未配置。
    def not_applicable?(name) = state(name) == :not_configured
    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class} platform=#{platform} states=#{@states}>"
    alias to_s inspect

    private

    # 不支持的平台保留扩展入口，不继承其他厂商的语法判断。
    def canonical_platform(value)
      ParserRegistry.canonical(value)
    rescue ArgumentError
      value.to_s.strip.downcase
    end

    # 推导可选功能已配置、未配置或未知的状态。
    def configuration_states(text, complete:)
      unknown = DIMENSIONS.to_h { |name| [ name, :unknown ] }
      return unknown unless SUPPORTED_PLATFORMS.include?(platform)

      source = CtxParser::Input.text(text, encoding: :transcode, newlines: :lf, max_bytes: MAX_BYTES)
      return unknown if /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/.match?(source)

      document = Document.new(source)
      return unknown if document.issues.any?

      roots = document.roots
      identity = platform == "h3c" ? /\Asysname\s+\S+\z/i : /\Ahostname\s+\S+\z/i
      recognized = roots.any? { |entry| identity.match?(entry.text) }
      family = platform == "h3c" ? :h3c : :cisco
      DIMENSIONS.to_h do |name|
        present, unresolved = feature_state(roots, family, name)
        value = if present
          :configured
        elsif complete && recognized && !unresolved
          :not_configured
        else
          :unknown
        end
        [ name, value ]
      end
    rescue ArgumentError, EncodingError
      unknown
    end

    # 仅在已声明的配置所属作用域中识别嵌套功能语句。
    def feature_state(roots, family, name)
      configured, unresolved = false, false
      roots.each do |entry|
        configured ||= ROOT_PATTERNS.fetch(family).fetch(name).match?(entry.text)
        if /\Ainterface\s+/i.match?(entry.text)
          pattern = INTERFACE_PATTERNS.fetch(family)[name]
          configured ||= pattern && entry.children.any? { |child| pattern.match?(child.text) }
          unresolved ||= feature_hint?(entry.text, name) || entry.children.any? { |child| feature_hint?(child.text, name) }
        elsif VRF.match?(entry.text)
          present, ambiguous = vrf_feature_state(entry.children, family, name)
          configured ||= present
          unresolved ||= ambiguous
        elsif HINTS.fetch(name).match?(entry.text) && !unrelated_setting?(entry.text)
          unresolved = true
        end
      end
      [ configured, unresolved ]
    end

    # 结合全局与 VRF 配置作用域判断协议是否适用。
    def vrf_feature_state(children, family, name)
      pending = children.dup
      unresolved = false
      until pending.empty?
        entry = pending.pop
        return [ true, unresolved ] if ROOT_PATTERNS.fetch(family).fetch(name).match?(entry.text)
        unresolved ||= feature_hint?(entry.text, name)
        pending.concat(entry.children) if ADDRESS_FAMILY.match?(entry.text)
      end
      [ false, unresolved ]
    end

    # 识别不能安全推断为功能缺失的声明。
    def feature_hint?(text, name) = HINTS.fetch(name).match?(text) && !unrelated_setting?(text)

    # 功能开关或描述值本身不能证明已配置运行实例。
    def unrelated_setting?(text)
      text.match?(/\A(?:no |undo )?(?:feature\s+\S+|logging\s+level\s+\S+\s+\d+|description\s+.*|hostname\s+\S+|sysname\s+\S+)\z/i)
    end

    # 领域语法负责注释、终端错误和横幅处理；缩进结构继续复用公共实现。
    class Document < CtxParser::Document
      protected

      # 区分配置结构行与引号、横幅中的文本内容。
      def classify(line)
        text = line.text
        return :ignored if text.empty?

        @banner ||= CtxParser::Banner.new
        # Comware 的可选关键字本身不能作为横幅分隔符。
        if !@banner.open? && /\Aheader\s+\S+\s+information\s*\z/i.match?(text)
          issues << { code: :invalid_banner, line: line.number }
          return :ignored
        end
        return :ignored if @banner.consume(text)
        if /\A(?:banner|header)\b/i.match?(text)
          issues << { code: :invalid_banner, line: line.number }
          return :ignored
        end
        if /--\s*More\s*--|Press (?:any key|ENTER|<SPACE>)|\A%\s*(?:Invalid|Incomplete|Ambiguous|Error)\b|\A(?:%\s*)?(?:Error:|Invalid (?:command|input|syntax)|Incomplete command|Ambiguous command|Permission denied|Insufficient privilege|Unrecognized command|Unknown command|command not (?:found|supported)|syntax error|\^-+\s*(?:unrecognized keyword|incomplete command|ambiguous command|error\b))/i.match?(text)
          issues << { code: :incomplete_configuration, line: line.number }
          return :ignored
        end
        return :boundary if text.start_with?("!", "#") || %w[end return].include?(text)
        return :ignored if /\A(?:Building configuration|Current configuration)/i.match?(text)

        :entry
      end

      # 汇总已解析记录，并报告未解决或不完整的来源状态。
      def finish
        issues << { code: :incomplete_banner } if @banner&.open?
      end
    end
    private_constant :Document
  end
end
