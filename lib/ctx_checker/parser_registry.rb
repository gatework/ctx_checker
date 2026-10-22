# frozen_string_literal: true

require "ctx_parser"
require_relative "h3c/profile"
require_relative "cisco_ios/profile"
require_relative "cisco_nxos/profile"
require_relative "palo_alto/profile"
require_relative "hillstone/profile"
require_relative "radware_alteon/profile"

module CtxChecker
  # 注册明确的平台别名与命令策略，不猜测不支持的语法。
  module ParserRegistry
    PROFILES = { h3c: H3c::Profile, cisco_ios: CiscoIos::Profile,
      cisco_nxos: CiscoNxos::Profile, palo_alto: PaloAlto::Profile, hillstone: Hillstone::Profile,
      radware_alteon: RadwareAlteon::Profile }.freeze
    ALIASES = { comware: :h3c, h3c_wireless: :h3c, ios: :cisco_ios, iosxe: :cisco_ios,
      ios_xe: :cisco_ios, cisco_iosxe: :cisco_ios, nxos: :cisco_nxos,
      paloalto: :palo_alto, panos: :palo_alto, stoneos: :hillstone, radware: :radware_alteon, alteon: :radware_alteon }.freeze
    REGISTRY = CtxParser::Registry.new(profiles: PROFILES, aliases: ALIASES)

    # 固件版本作为目标事实传入，仅由需要它的平台策略解释。
    def self.fetch(platform, model: nil, software_version: nil)
      unless software_version.nil? || software_version.is_a?(String) && !/[\x00-\x1f\x7f]/.match?(software_version)
        raise ArgumentError, "Software version must be text"
      end
      profile = REGISTRY.fetch(platform, model: model)
      profile.respond_to?(:with_software_version) ? profile.with_software_version(software_version) : profile
    end

    # 选择解析器与检查策略前，先归一化平台别名。
    def self.canonical(platform) = REGISTRY.canonical(platform).to_s
  end
end
