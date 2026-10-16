# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 逐光通道使用模块自身阈值，避免猜测统一的 dBm 限制。
    class Optics < Base
      ALARMS = %i[high_alarm low_alarm high_warning low_warning].freeze

      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        entity = record.slice(:interface, :lane, :metric)
        if inapplicable?(record)
          return finding(:unknown, :required_optics_inapplicable, entity: entity) if @policy.required_optics?(record)

          return finding(:not_applicable, :optics_not_applicable, entity: entity)
        end
        context = interface(record[:interface])
        if context && record_complete?(context, @snapshot.observation(:interfaces)) &&
            context[:admin_status] == :down && !@policy.required_interfaces.include?(record[:interface]) && !@policy.required_optics?(record)
          return finding(:not_applicable, :administratively_down, entity: entity)
        end
        if (record[:present] == false || record[:dom_supported] == false) && !ALARMS.include?(record[:alarm])
          return finding(:unknown, record[:present] == false ? :transceiver_absent : :dom_unavailable, entity: entity)
        end
        policy = @policy.optical_thresholds_for(record)
        thresholds = policy ? record.merge(Observation::OPTICAL_THRESHOLDS.to_h { |key| [ key, policy[key] ] }) : record
        measured = assess_thresholds(thresholds, entity)
        alarm = record[:alarm]
        explicit = if ALARMS.include?(alarm)
          finding(:fail, :optical_alarm, entity: entity, actual: alarm, severity: alarm.to_s.end_with?("warning") ? :warning : :critical)
        end
        results = explicit ? [ explicit ] : [ measured ]
        if explicit && measured.status == :fail && (policy || measured.severity == :critical && explicit.severity != :critical)
          results << measured
        end
        if explicit && measured.reason == :invalid_optical_thresholds
          results << measured
        elsif !policy && disagreement?(record, measured)
          results << finding(:unknown, :optical_alarm_threshold_disagreement, entity: entity,
            actual: { value: record[:value], alarm: alarm }, expected: record.slice(*Observation::OPTICAL_THRESHOLDS))
        end
        results
      end

      # 判定目标缺失需要完整枚举；未编号光通道仍保留身份歧义。
      def missing
        fields = Observation::IDENTITIES.fetch(:optics)
        identities = @observation.records.to_h { |row| [ row.values_at(*fields), true ] }
        unnumbered = @observation.records.select { |row| row[:lane].nil? }.to_h { |row| [ row.values_at(:interface, :metric), true ] }
        @policy.required_optics.filter_map do |identity|
          next if identities.key?(identity.values_at(*fields))

          ambiguous = unnumbered.key?(identity.values_at(:interface, :metric))
          finding(ambiguous ? :unknown : missing_status, :required_optics_missing, entity: identity, severity: :critical)
        end
      end

      # 仅完整且无矛盾的设备证据可以豁免铜缆端口的光学检查。
      def inapplicable?(record)
        record[:applicable] == false && record_complete?(record, @observation) &&
          record[:present] != true && record[:dom_supported] != true && record[:value].nil? &&
          record.values_at(*Observation::OPTICAL_THRESHOLDS).all?(&:nil?) && !ALARMS.include?(record[:alarm])
      end

      # 将支持的测量值与适用策略阈值比较。
      def assess_thresholds(record, entity)
        value = record[:value]
        return finding(:unknown, :optical_value_unavailable, entity: entity) if value.nil? || record[:unit] != :dbm

        bounds = record.values_at(*Observation::OPTICAL_THRESHOLDS)
        unless bounds.compact.each_cons(2).all? { |left, right| left <= right }
          return finding(:unknown, :invalid_optical_thresholds, entity: entity, actual: value)
        end
        severity = if bounds[0] && value < bounds[0] || bounds[3] && value > bounds[3]
          :critical
        elsif bounds[1] && value < bounds[1] || bounds[2] && value > bounds[2]
          :warning
        else
          :info
        end
        paired = bounds[0] && bounds[3] || bounds[1] && bounds[2]
        if severity == :info && !paired
          return finding(:unknown, :optical_thresholds_unavailable, entity: entity, actual: value)
        end
        finding(severity == :info ? :pass : :fail, :optical_threshold, entity: entity,
          actual: value, expected: record.slice(*Observation::OPTICAL_THRESHOLDS), severity: severity)
      end

      # 保留告警故障并报告来源冲突，不随意选择有利证据。
      def disagreement?(record, measured)
        alarm = record[:alarm]
        return measured.status == :fail if alarm == :normal
        return false unless ALARMS.include?(alarm) && record[:value] && record[:unit] == :dbm
        return true if measured.status == :fail && measured.severity == :critical && alarm.to_s.end_with?("warning")

        threshold = record[alarm]
        return false unless threshold

        alarm.to_s.start_with?("low") ? record[:value] >= threshold : record[:value] <= threshold
      end
    end
  end
end
