# frozen_string_literal: true

require_relative "../finding"

module CtxChecker
  module Checks
    # 共用证据边界；厂商特定文本不进入评估规则。
    class Base
      # 绑定当前维度评估使用的快照与策略。
      def initialize(snapshot:, policy:, previous: nil)
        @snapshot, @policy, @previous = snapshot, policy, previous
      end

      # 评估已知记录，分别表达必需、缺失与不完整证据。
      def call(observation)
        @observation = observation
        if observation.status == :not_applicable
          return [ finding(:fail, :required_feature_not_configured, severity: :critical) ] if @policy.required_dimension?(observation.name)

          return [ finding(:not_applicable, :feature_not_configured) ]
        end
        if observation.status == :not_requested && !@policy.required_dimension?(observation.name)
          return [ finding(:not_applicable, :not_requested) ]
        end
        results = observation.records.flat_map do |record|
          @current_record = record
          assess(record)
        ensure
          @current_record = nil
        end
        results.concat(missing)
        results << finding(:unknown, observation.complete? ? :empty_evidence : observation.status) if results.empty?
        results << finding(:unknown, :incomplete_evidence) unless observation.complete? || results.any? { |row| row.status == :unknown }
        results
      end

      private

      # 局部采集仍保留已知故障；判定成功则要求完整的支持证据。
      def finding(status, reason, entity: nil, actual: nil, expected: nil, severity: :info, suffix: nil)
        if status == :pass && !record_complete?(@current_record, @observation)
          status, reason = :unknown, :incomplete_evidence
        end
        Finding.new(id: [ @observation.name, suffix || reason ].join("."), dimension: @observation.name,
          entity: entity, status: status, reason: reason, actual: actual, expected: expected, severity: severity)
      end

      # 为策略要求但未观察到的资源生成证据缺失结果。
      def missing = []
      # 为不可用证据选择结果状态，不据此声明健康。
      def missing_status = @observation.complete? ? :fail : :unknown
      # 仅在需要关联接口状态的检查中建立接口索引。
      def interface(name)
        @interfaces_by_name ||= @snapshot.observation(:interfaces).records.to_h { |row| [ row[:name], row ] }
        @interfaces_by_name[name]
      end

      # 同级查询失败不能使其他来源的完整测量失效。
      def record_complete?(record, observation)
        return false if record && record[:source_complete] == false

        observation.complete? || observation.status == :partial && record && record[:source_complete] == true
      end
    end
  end
end
