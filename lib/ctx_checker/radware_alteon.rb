# frozen_string_literal: true

module CtxChecker
  # 打开厂商命名空间时，不从子解析器提前加载平台策略。
  module RadwareAlteon
    autoload(:Profile, File.expand_path("radware_alteon/profile", __dir__)) unless const_defined?(:Profile, false)
  end
end
