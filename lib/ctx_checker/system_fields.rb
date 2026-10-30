# frozen_string_literal: true

require "time"
require "ctx_parser/values"
require "ctx_parser/immutable"

module CtxChecker
  # 定义各系统观测维度的字段、身份及取值规则。
  module SystemFields
    FIELDS = CtxParser::Immutable.copy(
      cpu: %i[component scope window_seconds utilization interrupt_utilization],
      memory: %i[component scope utilization total_bytes used_bytes free_bytes available_bytes basis status],
      temperature: %i[component value low_alarm low_warning high_warning high_alarm high_comparison status],
      environment: %i[component kind status],
      power: %i[component kind status present watts capacity_watts],
      clock: %i[component time source synchronized],
      ntp: %i[component synchronized stratum reference peer_address offset_ms leap last_sync_status last_sync_at],
      alarms: %i[component alarm_id severity active count],
      device_counters: %i[component metric category value discontinuity sampled_at])
    IDENTITIES = CtxParser::Immutable.copy(cpu: %i[component scope window_seconds], memory: %i[component scope],
      temperature: %i[component], environment: %i[component kind], power: %i[component kind],
      clock: %i[component], ntp: %i[component], alarms: %i[component alarm_id], device_counters: %i[component metric])
    REQUIRED = CtxParser::Immutable.copy(FIELDS.keys.to_h do |name|
      fields = case name
      when :cpu, :memory then %i[component scope]
      when :alarms then %i[component alarm_id]
      when :device_counters then %i[component metric]
      else %i[component]
      end
      [ name, fields ]
    end)
    STATES = %i[ok warning critical failed absent unknown].freeze
    BASES = %i[used_total available used_minus_cache used_including_cache unknown].freeze
    CATEGORIES = %i[error discard policy informational unknown].freeze

    # 校验测量值，不将不可用读数转换为零或 false。
    def self.valid_value?(name, key, value)
      case key
      when :status then STATES.include?(value)
      when :basis then BASES.include?(value)
      when :kind
        (name == :power ? %i[power_supply power_rail unknown] : %i[fan voltage module clock overall unknown]).include?(value)
      when :severity then %i[info warning critical unknown].include?(value)
      when :category then CATEGORIES.include?(value)
      when :last_sync_status then %i[succeeded failed unknown].include?(value)
      when :high_comparison then %i[gt gte].include?(value)
      when :utilization, :interrupt_utilization then number?(value) && value.between?(0, 100)
      when :window_seconds, :total_bytes, :used_bytes, :free_bytes, :available_bytes, :count
        value.is_a?(Integer) && value >= 0
      when :stratum then value.is_a?(Integer) && value.between?(0, 16)
      when :leap then value.is_a?(Integer) && value.between?(0, 3)
      when :present, :synchronized, :active then value == true || value == false
      when :watts, :capacity_watts then number?(value) && value >= 0
      when :value then name == :device_counters ? value.is_a?(Integer) && value >= 0 : number?(value)
      when :low_alarm, :low_warning, :high_warning, :high_alarm, :offset_ms then number?(value)
      when :discontinuity then value.is_a?(Integer) && value >= 0 || text?(value)
      when :time, :sampled_at, :last_sync_at then timestamp?(value)
      else text?(value)
      end
    end

    # 识别有限数值策略值，不强制转换任意字符串。
    def self.number?(value) = value.is_a?(Numeric) && value.real? && value.finite?
    # 校验非空文本，拒绝将含控制字符的值作为标识。
    def self.text?(value) = value.is_a?(String) && !value.strip.empty? && !/[\x00-\x1f\x7f]/.match?(value)

    # 没有时区的本地时间不能安全地与采集器时间比较。
    def self.timestamp?(value)
      CtxParser::Values.timestamp(value)
      true
    rescue ArgumentError
      false
    end
  end
end
