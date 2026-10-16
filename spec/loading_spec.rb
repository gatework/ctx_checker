# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"
require "bundler"

RSpec.describe "CtxChecker standalone loading" do
  it "loads without Rails, Active Record, Netstack or net-connector" do
    library = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      require "ctx_checker"
      abort "unexpected dependency" if defined?(Rails) || defined?(ActiveRecord) || defined?(Net::Connector::Result) || $LOADED_FEATURES.any? { |path| path.include?("/netstack") && !path.end_with?("/version.rb") }
      puts CtxChecker::ParserRegistry::PROFILES.keys.sort.join(",")
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-rbundler/setup", "-I", library, "-e", script)
    expect(status.success?).to be(true), output
    expect(output).to eq("cisco_ios,cisco_nxos,h3c,hillstone,palo_alto,radware_alteon\n")
  end

  it "loads an Alteon child after the standalone entrypoint without recursively requiring its profile" do
    library = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      require "ctx_checker"
      require "ctx_checker/radware_alteon/parsers/info_link"
      puts CtxChecker::RadwareAlteon::Parsers::InfoLink.name
      puts CtxChecker::ParserRegistry.fetch(:radware).commands.fetch(:clock)
    RUBY
    output, status = Open3.capture2e(RbConfig.ruby, "-rbundler/setup", "-I", library, "-e", script)
    expect(status.success?).to be(true), output
    expect(output).to eq("CtxChecker::RadwareAlteon::Parsers::InfoLink\n/info/sys/general\n")
  end

  it "loads the entrypoint and runtime after standalone Alteon parser requires without a namespace cycle" do
    library = File.expand_path("../lib", __dir__)
    %w[info_link info_l3_ip stats_port_if info_sys_general].each do |name|
      script = <<~RUBY
        require "ctx_checker/radware_alteon/parsers/#{name}"
        require "ctx_checker"
        parser = CtxChecker::RuntimeParser.new(platform: :radware, software_version: "32.4.15.0")
        puts parser.platform
        puts parser.profile.commands.fetch(:optics)
      RUBY
      output, status = Open3.capture2e(RbConfig.ruby, "-rbundler/setup", "-I", library, "-e", script)
      expect(status.success?).to be(true), output
      expect(output).to eq("radware_alteon\n/info/transceiver\n")
    end
  end
end
