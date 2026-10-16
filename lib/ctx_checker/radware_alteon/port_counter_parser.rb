# frozen_string_literal: true

require_relative "../parsers/base"

module CtxChecker
  module RadwareAlteon
    # 动态端口查询绑定预期身份，不仅依赖命令回显确认目标。
    class PortCounterParser < CtxChecker::Parsers::Base
      # 各发现命令的目标绑定到其解析器类，避免共享可变状态。
      def self.for_port(number)
        raise ArgumentError, "Expected port must be a positive integer" unless number.is_a?(Integer) && number.positive?

        Class.new(self) { define_method(:expected_port) { "port#{number}" } }
      end

      private

      # 未绑定目标的解析器仍可用于已保存回显及独立格式回归。
      def expected_port = nil

      # 其他端口的响应不能算作请求端口的覆盖证据。
      def build_port_result(rows, complete:, recognized:, issues:)
        if expected_port
          mismatched = rows.reject { |row| row[:interface] == expected_port }
          if mismatched.any?
            issues << { code: :counter_port_mismatch, interface: expected_port }
            rows -= mismatched
          end
        end
        build_result(rows, complete: complete, recognized: recognized, issues: issues, identity: %i[interface metric])
      end
    end
  end
end
