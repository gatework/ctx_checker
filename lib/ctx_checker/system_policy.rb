# frozen_string_literal: true

require_relative "observation"

module CtxChecker
  # 运行限制由可配置策略定义，不作为硬件规格。
  class SystemPolicy
    DEFAULT_RESOURCES = CtxParser::Immutable.copy(cpu: { warning: 80, critical: 95 }, memory: { warning: 85, critical: 95 })
    attr_reader :resource_thresholds, :temperature_thresholds, :required_components,
      :required_dimensions, :max_clock_skew_seconds, :max_ntp_offset_ms, :device_counter_limits

    # 校验并冻结运行限制及必需组件选择。
    def initialize(resource_thresholds: {}, temperature_thresholds: {}, required_components: {}, required_dimensions: [],
      max_clock_skew_seconds: 300, max_ntp_offset_ms: 100, device_counter_limits: {})
      validate_resource_thresholds!(resource_thresholds)
      validate_temperature_thresholds!(temperature_thresholds)
      validate_required_components!(required_components)
      unless required_dimensions.is_a?(Array) && required_dimensions.uniq == required_dimensions && (required_dimensions - Observation::NAMES).empty?
        raise ArgumentError, "Required dimensions must be unique known names"
      end
      [ max_clock_skew_seconds, max_ntp_offset_ms ].each do |value|
        raise ArgumentError, "Time limits must be finite and nonnegative" unless SystemFields.number?(value) && value >= 0
      end
      unless device_counter_limits.is_a?(Hash) && device_counter_limits.all? { |metric, limit| SystemFields.text?(metric) && limit.is_a?(Integer) && limit >= 0 }
        raise ArgumentError, "Device counter limits require named metrics and nonnegative integer deltas"
      end
      @resource_thresholds = CtxParser::Immutable.copy(DEFAULT_RESOURCES.merge(resource_thresholds))
      @temperature_thresholds, @required_components, @required_dimensions, @device_counter_limits =
        [ temperature_thresholds, required_components, required_dimensions, device_counter_limits ].map { |value| CtxParser::Immutable.copy(value) }
      @max_clock_skew_seconds, @max_ntp_offset_ms = max_clock_skew_seconds, max_ntp_offset_ms
      freeze
    end

    # 检查策略是否明确要求此资源或功能。
    def required_dimension?(name) = required_dimensions.include?(name) || required_components.fetch(name, []).any?

    private

    # 两个资源阈值必须明确且有序，拒绝仅替换其中一个。
    def validate_resource_thresholds!(values)
      unless values.is_a?(Hash) && (values.keys - DEFAULT_RESOURCES.keys).empty? && values.values.all? do |row|
          row.is_a?(Hash) && row.keys.sort == %i[critical warning] && row.values.all? { |value| SystemFields.number?(value) && value.between?(0, 100) } && row[:warning] <= row[:critical]
        end
        raise ArgumentError, "Resource thresholds require ordered warning and critical percentages"
      end
    end

    # 校验温度限制及各传感器的策略覆盖值。
    def validate_temperature_thresholds!(values)
      unless values.is_a?(Hash) && values.all? do |component, row|
          SystemFields.text?(component) && row.is_a?(Hash) && (row.keys & Observation::OPTICAL_THRESHOLDS).any? &&
            (row.keys - Observation::OPTICAL_THRESHOLDS - [ :high_comparison ]).empty? &&
            (!row.key?(:high_comparison) || %i[gt gte].include?(row[:high_comparison])) &&
            row.except(:high_comparison).values.all? { |value| SystemFields.number?(value) } &&
            row.values_at(*Observation::OPTICAL_THRESHOLDS).compact.each_cons(2).all? { |low, high| low <= high }
        end
        raise ArgumentError, "Temperature policies require exact sensors and ordered Celsius limits"
      end
    end

    # 校验必需环境组件与允许的状态。
    def validate_required_components!(values)
      unless values.is_a?(Hash) && (values.keys - %i[temperature environment power]).empty? && values.values.all? do |names|
          names.is_a?(Array) && names.uniq == names && names.all? { |name| SystemFields.text?(name) }
        end
        raise ArgumentError, "Required hardware components must be unique names by dimension"
      end
    end
  end
end
