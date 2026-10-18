# frozen_string_literal: true

require "rubygems/package"
require "tmpdir"
require "rbconfig"

# 仅验证发布文件与解析后的依赖，避免从工作区加载代码。
artifact = File.expand_path(ARGV.fetch(0))
dependencies = ARGV.drop(1).map { |path| File.expand_path(path) }
spec = Gem::Package.new(artifact).spec
abort "Unexpected package" unless spec.name == "ctx_checker"
abort "Unexpected package contents" if spec.files.any? { |path| path.start_with?("spec/", "test/", "storage/", "tmp/") || path.end_with?(".log", ".gem") }
Dir.mktmpdir("gem-install-") do |home|
  env = ENV.to_h.keys.grep(/\A(?:BUNDLE_|BUNDLER_|RUBY)/).to_h { |key| [ key, nil ] }
  env.merge!("GEM_HOME" => home, "GEM_PATH" => home, "RUBYOPT" => nil, "RUBYLIB" => nil)
  ruby = RbConfig.ruby
  # 联动开发可显式传入依赖候选包；默认仍验证注册表解析出的依赖。
  dependencies.each do |dependency|
    system(env, ruby, "-S", "gem", "install", dependency, "--no-document", exception: true)
  end
  system(env, ruby, "-S", "gem", "install", artifact, "--no-document", exception: true)
  check = <<~RUBY
    require "ctx_checker"
    abort "Unexpected Rails dependency" if defined?(Rails)
    loaded = Gem.loaded_specs.fetch("ctx_checker")
    abort "Loaded checkout instead of package" unless File.realpath(loaded.full_gem_path).start_with?(File.realpath(ENV.fetch("GEM_HOME")) + "/")
    abort "Version mismatch" unless loaded.version.to_s == #{spec.version.to_s.inspect}
    Dir[File.join(loaded.full_gem_path, "examples/**/*.rb")].sort.each { |path| load path }
    # 接口示例不经过地址转换；用合成 BGP 回显验证已安装的解析依赖。
    bgp = <<~CLI
      BGP summary information for VRF blue, address family IPv4 Unicast
      Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
      192.0.2.1 4 65001 0 0 0 0 0 00:01:00 0
    CLI
    observation = CtxChecker::RuntimeParser.new(platform: :cisco_ios).parse(:bgp, bgp, complete: true)
    abort "Installed BGP parser did not produce complete evidence" unless observation.complete? && observation.issues.empty?
    expected = { vrf: "blue", afi_safi: "ipv4_unicast", peer: "192.0.2.1", state: :established,
      received_prefixes: 0, remote_as: 65001, source_complete: true }
    abort "Installed BGP parser changed neighbor facts" unless observation.records == [ expected ]
  RUBY
  system(env, ruby, "-e", check, chdir: home, exception: true)
end
