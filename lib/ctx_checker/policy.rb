# frozen_string_literal: true

require_relative "observation"
require_relative "system_policy"

module CtxChecker
  # 使用显式设备预期，不猜测未声明的拓扑或光学阈值。
  class Policy
    attr_reader :required_interfaces, :required_members, :minimum_active_members, :expected_bgp, :expected_ospf, :counter_limits, :optical_thresholds, :required_optics, :system

    # 在设备评估前校验并冻结策略定义。
    def initialize(required_interfaces: [], required_members: {}, minimum_active_members: {}, expected_bgp: [], expected_ospf: [], counter_limits: {}, optical_thresholds: [],
      resource_thresholds: {}, temperature_thresholds: {}, required_components: {}, required_dimensions: [], required_optics: [],
      max_clock_skew_seconds: 300, max_ntp_offset_ms: 100, device_counter_limits: {})
      @system = SystemPolicy.new(resource_thresholds: resource_thresholds, temperature_thresholds: temperature_thresholds,
        required_components: required_components, required_dimensions: required_dimensions, max_clock_skew_seconds: max_clock_skew_seconds,
        max_ntp_offset_ms: max_ntp_offset_ms, device_counter_limits: device_counter_limits)
      validate_interface_names!(required_interfaces)
      unless required_members.is_a?(Hash) && required_members.all? { |group, members| text?(group) && validate_interface_names!(members) }
        raise ArgumentError, "Required members must map groups to interface names"
      end
      unless minimum_active_members.is_a?(Hash) && minimum_active_members.all? { |group, count| text?(group) && count.is_a?(Integer) && count.positive? }
        raise ArgumentError, "Minimum active members must be positive integers"
      end
      validate_neighbor_identities!(expected_bgp, %i[vrf afi_safi peer_address])
      validate_neighbor_identities!(expected_ospf, %i[vrf process_id interface router_id])
      expected_ospf = expected_ospf.map do |identity|
        identity[:process_id].is_a?(Integer) ? identity.merge(process_id: identity[:process_id].to_s) : identity
      end
      validate_neighbor_identities!(expected_ospf, %i[vrf process_id interface router_id])
      unless counter_limits.is_a?(Hash) && counter_limits.all? { |metric, count| Observation::METRICS.include?(metric) && count.is_a?(Integer) && count >= 0 }
        raise ArgumentError, "Counter limits must be nonnegative integer deltas"
      end
      validate_optical_thresholds!(optical_thresholds)
      validate_required_optics!(required_optics)
      @required_interfaces, @required_members, @minimum_active_members, @expected_bgp, @expected_ospf, @counter_limits =
        [ required_interfaces, required_members, minimum_active_members, expected_bgp, expected_ospf, counter_limits ].map { |value| CtxParser::Immutable.copy(value) }
      @required_interface_index = @required_interfaces.to_h { |name| [ name, true ] }.freeze
      @optical_thresholds = CtxParser::Immutable.copy(optical_thresholds)
      @optical_index = @optical_thresholds.to_h { |row| [ row.values_at(:interface, :lane, :metric).freeze, row ] }.freeze
      @required_optics = CtxParser::Immutable.copy(required_optics)
      @required_optical_index = @required_optics.to_h { |row| [ row.values_at(:interface, :lane, :metric).freeze, true ] }.freeze
      freeze
    end

    # 按接口身份查询策略要求，避免逐条测量重复遍历列表。
    def required_interface?(name) = @required_interface_index.key?(name)

    # 策略仅替换精确光通道及指标的阈值，不改变设备告警证据。
    def optical_thresholds_for(record) = @optical_index[record.values_at(:interface, :lane, :metric)]
    # 检查策略是否要求此接口提供光学诊断。
    def required_optics?(record) = @required_optical_index.key?(record.values_at(:interface, :lane, :metric))

    # 检查策略是否明确要求此资源或功能。
    def required_dimension?(name)
      return true if system.required_dimension?(name)
      case name
      when :interfaces then required_interfaces.any?
      when :aggregation then required_members.any? || minimum_active_members.any?
      when :bgp then expected_bgp.any?
      when :ospf then expected_ospf.any?
      when :optics then required_optics.any?
      else false
      end
    end

    private

    # 校验非空文本，拒绝将含控制字符的值作为标识。
    def text?(value) = value.is_a?(String) && !value.strip.empty? && !/[\x00-\x1f\x7f]/.match?(value)

    # 校验策略选择器使用的资源名称是否有效且不重复。
    def validate_interface_names!(values)
      raise ArgumentError, "Interface names must be unique text" unless values.is_a?(Array) && values.all? { |value| text?(value) } && values.uniq == values
      true
    end

    # 校验协议对等体身份及对应策略要求。
    def validate_neighbor_identities!(values, fields)
      unless values.is_a?(Array) && values.uniq == values && values.all? do |row|
          row.is_a?(Hash) && row.keys.sort == fields.sort && row.all? { |key, value| text?(value) || key == :process_id && value.is_a?(Integer) && value >= 0 }
        end
        raise ArgumentError, "Expected peers require complete scoped identities"
      end
    end

    # 校验光功率阈值及必需接口选择。
    def validate_optical_thresholds!(values)
      fields = %i[interface lane metric] + Observation::OPTICAL_THRESHOLDS
      unless values.is_a?(Array) && values.all? { |row| row.is_a?(Hash) && (row.keys - fields).empty? }
        raise ArgumentError, "Optical policies require scoped threshold records"
      end
      observation = Observation.new(name: :optics, status: :complete, records: values)
      observation.records.each do |row|
        thresholds = row.values_at(*Observation::OPTICAL_THRESHOLDS)
        paired = row[:low_alarm] && row[:high_alarm] || row[:low_warning] && row[:high_warning]
        unless paired && thresholds.compact.each_cons(2).all? { |low, high| low <= high }
          raise ArgumentError, "Optical policies require an ordered complete alarm or warning pair"
        end
      end
    end

    # 必需测量必须有明确身份；仅配置阈值不表示要求资源存在。
    def validate_required_optics!(values)
      fields = %i[interface lane metric]
      unless values.is_a?(Array) && values.all? { |row| row.is_a?(Hash) && row.keys.sort == fields }
        raise ArgumentError, "Required optics need exact interface, lane and metric identities"
      end
      Observation.new(name: :optics, status: :complete, records: values)
    end
  end
end
