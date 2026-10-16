# frozen_string_literal: true

module CtxChecker
  module H3c
    module Parsers
      # 共享 Comware 标量转换；测量缺失始终不能变成零。
      module SystemValues
        NUMBER = /(?:-?\d+(?:\.\d+)?|--|N\/?A|error)/i
        COMPONENT_STATES = { "normal" => :ok, "ok" => :ok, "fault" => :failed,
          "faulty" => :failed, "error" => :failed, "fandirectionfault" => :failed,
          "absent" => :absent, "warning" => :warning }.freeze

        private

        # 解析支持的传感器测量值及回显单位。
        def measurement(value, field:, component:, percent: false)
          return if value.nil? || /\A(?:--|N\/?A|error)\z/i.match?(value)
          number = Float(value, exception: false)
          return number if number&.finite? && (!percent || (0..100).cover?(number))

          @issues << { code: :invalid_measurement, field: field, component: component }
          nil
        end

        # 解析非负计数，同时保留未知值。
        def count(value, field:, component:)
          return value.to_i if /\A\d+\z/.match?(value.to_s)

          @issues << { code: :invalid_measurement, field: field, component: component }
          nil
        end

        # 按平台支持的标签归一化硬件组件状态。
        def component_state(value, component:)
          COMPONENT_STATES.fetch(value.downcase) do
            @issues << { code: :unrecognized_component_state, component: component }
            :unknown
          end
        end

        # 确定模块或路由上下文的身份。
        def scope_name(value) = value.downcase.strip.gsub(/\s+/, " ")
      end
    end
  end
end
