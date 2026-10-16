# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"

RSpec.describe "NX-OS time command variants" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :cisco_nxos) }
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/cisco_nxos/ntp_variants.txt", __dir__)) }

  def parse(body, complete: true)
    parser.parse(:ntp, body, complete: complete)
  end

  it "accepts empty local-clock VRFs and a VRF immediately following the delay value" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records.first).to include(synchronized: true, stratum: 3, peer: "192.0.2.20")
  end

  it "accepts older tables without the optional VRF column" do
    result = parse(text.sub("delay vrf", "delay").sub("0.00107default", "0.00107"))
    expect(result).to be_complete
    expect(result.records.first[:synchronized]).to be(true)
  end

  it "accepts compact legend spacing from Nexus 5500 output" do
    body = text.sub("* - selected", "*-selected").sub("- - peer mode", "--peer mode")
    expect(parse(body)).to be_complete
  end

  it "assembles wrapped table headers and peers without crossing an incomplete row" do
    body = <<~TEXT
      Total peers : 1
      remote local
      st poll reach delay vrf
      --------------------------------
      *192.0.2.20 192.0.2.10
      2 64 377 0.00107default
    TEXT
    expect(parse(body)).to be_complete
    expect(parse(body).records.first[:synchronized]).to be(true)
    truncated = body.lines.reject { |line| line.start_with?("2 64") }.join
    expect(parse(truncated).issues).to include(include(code: :truncated_ntp_peer))
    expect(parse(truncated).records.first[:synchronized]).to be_nil
    interrupted = truncated + "Total peers : 1\n2 64 377 0.00107default\n"
    expect(parse(interrupted).records.first[:peer]).to be_nil
    expect(parse("Total peers : 1\nremote local\n").issues).to include(include(code: :truncated_ntp_header))
  end

  it "accepts IPv6 peers while rejecting subnet and scoped-address tokens as peer identities" do
    ipv6 = text.gsub("192.0.2.10", "2001:db8::10").gsub("192.0.2.20", "2001:db8::20")
    expect(parse(ipv6)).to be_complete
    [ "192.0.2.20/24", "fe80::20%mgmt0" ].each do |address|
      result = parse(text.sub("192.0.2.20", address))
      expect(result.status).to eq(:partial)
      expect(result.records.first[:synchronized]).to be_nil
    end
  end

  it "requires the peer table header and does not infer a missing column layout" do
    result = parse(text.lines.reject { |line| line.include?("remote") }.join)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :missing_ntp_header))
    expect(result.records.first[:synchronized]).to be_nil
  end

  it "rejects malformed delay values and unexpected trailing columns" do
    [ "-0.00107default", "N/A default", "0.00107 default extra", "1e99", "#{'9' * 400} default" ].each do |value|
      result = parse(text.sub("0.00107default", value))
      expect(result.status).to eq(:partial)
      expect(result.records.first[:synchronized]).to be_nil
    end
  end

  it "distinguishes the local reference clock from synchronization to an external peer" do
    body = "Total peers : 1\nremote local st poll reach delay vrf\n*127.127.1.0 192.0.2.10 8 16 377 0.00000\n"
    result = parse(body)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :local_ntp_reference))
    expect(result.records.first[:synchronized]).to be_nil
    mapped = parse(body.sub("127.127.1.0", "::ffff:127.127.1.0"))
    expect(mapped.issues).to include(include(code: :local_ntp_reference))
    expect(mapped.records.first[:synchronized]).to be_nil
    expect(parse(text.sub("192.0.2.20", "::ffff:192.0.2.20")).records.first[:peer]).to eq("192.0.2.20")
  end

  it "retains strict reachability, peer count and completeness boundaries" do
    %w[400 999 -1].each do |reach|
      expect(parse(text.sub("377", reach)).records.first[:synchronized]).to be_nil
    end
    expect(parse(text.sub("Total peers : 2", "Total peers : 3")).records.first[:synchronized]).to be_nil
    expect(parse(text, complete: false).status).to eq(:partial)
    expect(parse("Total peers : 0\n").records.first[:synchronized]).to be(false)
    expect(parse("Total peers : 0\n", complete: false).records.first[:synchronized]).to be_nil
    expect(parse("% Invalid command\n").status).to eq(:unsupported)
  end

  it "keeps supported NX clock source ordering while refusing ambiguous timezone abbreviations" do
    body = "Time source is NTP\n09:02:03.125 UTC Fri Oct 16 2026\n"
    row = parser.parse(:clock, body, complete: true).records.first
    expect(row).to include(time: "2026-10-16T09:02:03.125+00:00", source: "NTP", synchronized: nil)
    expect(parser.parse(:clock, body.sub("UTC", "CST"), complete: true).records.first[:time]).to be_nil
  end
end
