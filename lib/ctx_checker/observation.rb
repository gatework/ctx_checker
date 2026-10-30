# frozen_string_literal: true

require "ctx_parser/immutable"
require "ctx_runner/observation"
require "ctx_runner/document"
require "time"
require "forwardable"
require_relative "system_fields"

module CtxChecker
  # 提供经过校验的不可变运行事实，与后续健康评估相互独立。
  class Observation < CtxRunner::Observation
    include CtxRunner::Document::Value
    NAMES = (%i[interfaces counters aggregation optics bgp ospf] + SystemFields::FIELDS.keys).freeze
    STATUSES = %i[complete partial failed unsupported not_requested not_applicable].freeze
    METRICS = %i[in_errors out_errors in_discards out_discards crc_errors stomped_crc_errors out_carrier_errors].freeze
    COUNTER_UNITS = %i[packets bytes events unknown].freeze
    COUNTER_SCOPES = %i[interface mac cpu logical queue unknown].freeze
    OPTICAL_THRESHOLDS = %i[low_alarm low_warning high_warning high_alarm].freeze
    FIELDS = CtxParser::Immutable.copy({
      interfaces: %i[name kind admin_status oper_status protocol_status protocol_applicable parent],
      counters: %i[interface metric value unit scope discontinuity sampled_at source_command],
      aggregation: %i[group member member_status oper_status],
      optics: %i[interface lane metric value unit low_alarm low_warning high_warning high_alarm alarm present dom_supported applicable],
      bgp: %i[vrf afi_safi peer_address state received_prefixes remote_as],
      ospf: %i[vrf process_id area interface router_id neighbor_address state network_type local_role neighbor_role], **SystemFields::FIELDS
    }.transform_values { |fields| fields + [ :source_complete ] })
    IDENTITIES = CtxParser::Immutable.copy(interfaces: %i[name], counters: %i[interface metric],
      aggregation: %i[group member], optics: %i[interface lane metric], bgp: %i[vrf afi_safi peer_address],
      ospf: %i[vrf process_id interface router_id neighbor_address], **SystemFields::IDENTITIES)
    REQUIRED = CtxParser::Immutable.copy(interfaces: %i[name], counters: %i[interface metric],
      aggregation: %i[group], optics: %i[interface metric], bgp: %i[peer_address], ospf: %i[router_id], **SystemFields::REQUIRED)
    ISSUE_FIELDS = %i[code line lines field count skipped interface metric metrics lane section expected observed group stage component scope window_seconds command error_type].freeze
    ERROR_TYPE_PATTERN = /\A(?:[A-Z][A-Za-z0-9_]*::)*[A-Z][A-Za-z0-9_]*\z/
    ENUMS = CtxParser::Immutable.copy(
      kind: %i[physical aggregate bridge redundant svi loopback tunnel subinterface unknown],
      admin_status: %i[up down unknown], oper_status: %i[up down unknown], protocol_status: %i[up down unknown],
      member_status: %i[active standby down suspended unselected unknown], unit: %i[dbm],
      alarm: %i[normal high_alarm high_warning low_warning low_alarm unknown],
      network_type: %i[broadcast nbma point_to_point point_to_multipoint virtual_link unknown],
      local_role: %i[dr bdr drother unknown], neighbor_role: %i[dr bdr drother unknown])
    SCOPE_FIELDS = CtxParser::Immutable.copy(bgp: %i[vrf afi_safi], ospf: %i[vrf process_id interface])
    # 冻结单个维度的记录、状态及诊断元数据。
    def initialize(name:, status:, records: [], issues: [], evidence: [], covered_scopes: [], started_at: nil, completed_at: nil)
      raise ArgumentError, "Unknown observation dimension" unless NAMES.include?(name)
      CtxRunner::Observation.validate(name: name, status: status, records: records, issues: issues, evidence: evidence, statuses: STATUSES)
      validate_scopes!(covered_scopes, name: name, status: status)
      covered_scopes = covered_scopes.map do |scope|
        scope[:process_id].is_a?(Integer) ? scope.merge(process_id: scope[:process_id].to_s) : scope
      end
      validate_scopes!(covered_scopes, name: name, status: status)
      normalized = records.map { |record| validate_record(record, name) }
      identities = normalized.map { |record| record.values_at(*IDENTITIES.fetch(name)) }
      raise ArgumentError, "Duplicate observation identity" unless identities.uniq.size == identities.size
      unless issues.is_a?(Array) && issues.all? { |issue| self.class.valid_issue?(issue) }
        raise ArgumentError, "Observation issues require safe codes"
      end
      super(name: name, status: status, records: normalized, issues: issues,
        evidence: evidence, covered_scopes: covered_scopes, started_at: started_at, completed_at: completed_at)
      freeze
    end

    # 返回用于关联同一资源多次采样的稳定字段。
    def identity(record) = record.values_at(*IDENTITIES.fetch(name))
    # 展示对象身份与状态，避免泄露原始回显或凭据。
    def inspect = "#<#{self.class} name=#{name} status=#{status} records=#{records.size}>"

    # 命令失败与快照失败共用安全诊断结构。
    def self.valid_issue?(issue)
      return false unless issue.is_a?(Hash) && (issue.keys - ISSUE_FIELDS).empty?

      code = issue[:code]
      return false unless (code.is_a?(Symbol) || code.is_a?(String)) && /\A[a-z][a-z0-9_]*\z/.match?(code.to_s)

      !issue.key?(:error_type) || issue[:error_type].is_a?(String) && ERROR_TYPE_PATTERN.match?(issue[:error_type])
    end

    private

    # 完整协议表仅覆盖其明确的 VRF、地址族或 OSPF 进程。
    def validate_scopes!(scopes, name:, status:)
      unless scopes.is_a?(Array) && scopes.uniq == scopes
        raise ArgumentError, "Covered scopes must be a unique array"
      end
      return if scopes.empty?

      fields = SCOPE_FIELDS[name]
      required = name == :ospf ? %i[vrf process_id] : fields
      unless fields && %i[complete partial].include?(status) && scopes.all? do |scope|
          scope.is_a?(Hash) && (scope.keys - fields).empty? && (required - scope.keys).empty? &&
            scope.all? { |key, value| text?(value) || key == :process_id && value.is_a?(Integer) && value >= 0 }
        end
        raise ArgumentError, "Covered scopes require explicit protocol identities"
      end
    end

    # 测量缺失保留 nil；身份字段不能静默消失。
    def validate_record(record, name)
      unless record.is_a?(Hash) && (record.keys - FIELDS.fetch(name)).empty?
        raise ArgumentError, "Unsupported observation record fields"
      end
      row = FIELDS.fetch(name).each_with_object({}) { |key, values| values[key] = record[key] }
      raise ArgumentError, "Missing observation identity" unless REQUIRED.fetch(name).all? { |key| !row[key].nil? }
      row.each do |key, value|
        next if value.nil?
        valid = if key == :source_complete
          value == true || value == false
        elsif SystemFields::FIELDS.key?(name)
          SystemFields.valid_value?(name, key, value)
        elsif key == :sampled_at
          SystemFields.timestamp?(value)
        elsif name == :counters && key == :unit
          COUNTER_UNITS.include?(value)
        elsif name == :counters && key == :scope
          COUNTER_SCOPES.include?(value)
        elsif ENUMS.key?(key)
          ENUMS.fetch(key).include?(value)
        elsif key == :metric
          (name == :optics ? %i[tx_power rx_power] : METRICS).include?(value)
        elsif key == :state
          states = name == :bgp ? %i[established idle active connect opensent openconfirm shutdown unknown] : %i[full two_way down attempt init exstart exchange loading unknown]
          states.include?(value)
        elsif %i[value low_alarm low_warning high_warning high_alarm].include?(key)
          name == :counters ? value.is_a?(Integer) && value >= 0 : value.is_a?(Numeric) && value.real? && value.finite?
        elsif %i[received_prefixes remote_as].include?(key)
          value.is_a?(Integer) && value >= 0
        elsif %i[present dom_supported applicable protocol_applicable].include?(key)
          value == true || value == false
        elsif key == :lane || key == :discontinuity || key == :process_id
          value.is_a?(Integer) && value >= 0 || text?(value)
        else
          text?(value)
        end
        raise ArgumentError, "Invalid #{name} field #{key}" unless valid
      end
      row[:process_id] = row[:process_id].to_s if name == :ospf && row[:process_id].is_a?(Integer)
      row
    end

    # 校验非空文本，拒绝将含控制字符的值作为标识。
    def text?(value) = value.is_a?(String) && !value.strip.empty? && !/[\x00-\x1f\x7f]/.match?(value)
  end
end
