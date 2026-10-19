# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Runtime source separators" do
  it "keeps whitespace fields and diagnostics independent of the process field separator" do
    script = <<~'RUBY'
      require "ctx_checker"
      sources = [
        [:cisco_ios, :optics, "optics", 2],
        [:cisco_ios, :temperature, "catalyst9500_environment", 2],
        [:cisco_ios, :environment, "catalyst9500_environment", 4],
        [:cisco_ios, :power, "catalyst9500_environment", 3],
        [:cisco_nxos, :bgp, "bgp_summary", 3],
        [:h3c, :memory, "memory", 2],
        [:palo_alto, :temperature, "environmentals", 2],
        [:palo_alto, :environment, "environmentals", 3],
        [:palo_alto, :power, "environmentals", 3]
      ].map do |platform, dimension, fixture, count|
        [platform, dimension, File.read("spec/fixtures/ctx_checker/#{platform}/#{fixture}.txt"), count]
      end
      sources << [:h3c, :cpu, "Chassis Slot CPU Last 5 sec Last 1 min Last 5 min\n1 2 0 11% 12% 13%\n", 3]
      sources << [:cisco_ios, :bgp, <<~CLI, 1]
        BGP summary information for VRF blue, address family IPv4   Unicast
        Neighbor V AS MsgRcvd MsgSent TblVer InQ OutQ Up/Down State/PfxRcd
        192.0.2.1 4 65001 0 0 0 0 0 00:01:00 0
      CLI
      samples = sources.map do |platform, dimension, body, count|
        parser = CtxChecker::RuntimeParser.new(platform: platform)
        expected = parser.parse(dimension, body, complete: true)
        unless expected.complete? && expected.records.size == count && expected.issues.empty?
          abort "Invalid baseline: #{platform}/#{dimension} #{expected.to_h.inspect}"
        end
        [platform, dimension, parser, body, expected.to_h]
      end
      failures = []
      [",", /[:,]/, " ", nil].each do |separator|
        $; = separator
        samples.each do |platform, dimension, parser, body, expected|
          actual = parser.parse(dimension, body, complete: true)
          next if actual.to_h == expected

          failures << "Changed #{platform}/#{dimension} with #{separator.inspect}: #{actual.status} (#{actual.records.size} records)"
        end
      end
      abort failures.join("\n") unless failures.empty?
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)

    expect(status.success?).to be(true), "#{output}#{error}"
  end

  it "keeps facts and diagnostics independent of process input and output separators" do
    script = <<~'RUBY'
      require "ctx_checker"
      sources = {
        h3c: "interfaces", cisco_ios: "interfaces", cisco_nxos: "interface",
        hillstone: "interfaces_live", palo_alto: "interfaces", radware_alteon: "link_5424_32415"
      }
      samples = sources.map do |platform, fixture|
        body = File.read("spec/fixtures/ctx_checker/#{platform}/#{fixture}.txt")
        parser = CtxChecker::RuntimeParser.new(platform: platform)
        expected = parser.parse(:interfaces, body, complete: true, command: parser.profile.commands_for(:interfaces).first)
        usable = expected.complete? || platform == :radware_alteon && expected.status == :partial &&
          expected.issues.all? { |issue| issue[:code] == :incomplete_command_set }
        abort "Empty baseline: #{platform}" unless usable && expected.records.any?
        [platform, parser, body, expected.to_h]
      end
      h3c = CtxChecker::RuntimeParser.new(platform: :h3c)
      body = File.read("spec/fixtures/ctx_checker/h3c/interfaces.txt")
      expected = h3c.parse(:counters, body, complete: true, command: "display interface")
      abort "Missing counter baseline" unless expected.records.any? { |row| !row[:value].nil? }
      samples << [:h3c_counters, h3c, body, expected.to_h]
      ["\n", nil, "|", ""].each do |separator|
        $/ = separator
        $, = "INJECTED"
        samples.each do |platform, parser, body, expected|
          dimension = platform == :h3c_counters ? :counters : :interfaces
          command = dimension == :counters ? "display interface" : parser.profile.commands_for(dimension).first
          actual = parser.parse(dimension, body, complete: true, command: command)
          abort "Changed #{platform} with #{separator.inspect}" unless actual.to_h == expected
        end
      end
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)

    expect(status.success?).to be(true), "#{output}#{error}"
  end
end
