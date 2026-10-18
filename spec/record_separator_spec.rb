# frozen_string_literal: true

require_relative "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Runtime source separators" do
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
