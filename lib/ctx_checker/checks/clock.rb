# frozen_string_literal: true

require_relative "base"

module CtxChecker
  module Checks
    # 依据明确的 UTC 偏移，以命令采集时间计算设备时钟偏差。
    class Clock < Base
      private

      # 按策略评估资源，同时保留测量值缺失的状态。
      def assess(record)
        entity = { component: record[:component] }
        results = []
        if record[:synchronized] == false
          results << finding(:fail, :clock_unsynchronized, entity: entity, severity: :warning)
        end
        unless record[:time]
          return results + [ finding(:unknown, :clock_time_unavailable, entity: entity) ]
        end
        observed_at = @observation.observed_at || @snapshot.observed_at
        skew = (Time.iso8601(record[:time]) - observed_at).abs
        limit = @policy.system.max_clock_skew_seconds
        results << finding(skew > limit ? :fail : :pass, :clock_skew, entity: entity,
          actual: { time: record[:time], skew_seconds: skew }, expected: { maximum_seconds: limit }, severity: skew > limit ? :warning : :info)
        results
      end
    end
  end
end
