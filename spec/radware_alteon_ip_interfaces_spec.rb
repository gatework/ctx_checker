# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"
require "ctx_checker/radware_alteon/parsers/info_l3_ip"

RSpec.describe CtxChecker::RadwareAlteon::Parsers::InfoL3Ip do
  let(:text) { File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/ip_5424_32415.txt", __dir__)) }

  # 逻辑接口状态解析独立于物理端口发现。
  def parse(text, complete: true)
    described_class.new.parse(text, complete: complete)
  end

  it "uses IP-interface indexes rather than VLAN IDs and excludes numbered gateways" do
    result = parse(text)
    expect(result).to be_complete
    expect(result.records.size).to eq(8)
    expect(result.records).to include(include(name: "ipif1", kind: :svi, oper_status: :up,
      admin_status: :unknown, protocol_status: :unknown, protocol_applicable: true))
    expect(result.records).not_to include(include(name: "ipif100"), include(name: "ipif2"))
  end

  it "retains a down logical interface without inventing a separate line protocol status" do
    result = parse(text.sub(", up, BFD off", ", down, BFD off"))
    expect(result).to be_complete
    expect(result.records.first).to include(oper_status: :down, protocol_status: :unknown)
  end

  it "does not trust malformed addresses or noncontiguous subnet masks" do
    bad_address = parse(text.sub("192.0.2.1", "999.0.2.1"))
    expect(bad_address.status).to eq(:partial)
    expect(bad_address.records).not_to include(include(name: "ipif1"))
    bad_mask = parse(text.sub("255.255.255.0", "255.0.255.0"))
    expect(bad_mask.status).to eq(:partial)
    expect(bad_mask.records).not_to include(include(name: "ipif1"))
  end

  it "requires section terminators before treating a captured inventory as complete" do
    result = parse(text.split("IPv6 Link Local Address Information:").first)
    expect(result.status).to eq(:partial)
    expect(result.records.size).to eq(8)
    expect(parse(text, complete: false).status).to eq(:partial)
  end

  it "keeps unadapted IPv6 link-local rows explicit instead of declaring full logical coverage" do
    result = parse(text.sub("IPv6 Link Local Address Information:\n", "IPv6 Link Local Address Information:\n1: fe80::1 up\n"))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :ipv6_interface_evidence_unavailable))
  end

  it "removes duplicate indexes and preserves unfamiliar states as unknown" do
    duplicate = parse(text.sub(",Interface information:", ",Interface information:\n#{text.lines.grep(/^\s*1: IP4/).first}"))
    expect(duplicate.status).to eq(:partial)
    expect(duplicate.records).not_to include(include(name: "ipif1"))
    unknown = parse(text.sub(", up, BFD off", ", testing, BFD off"))
    expect(unknown.status).to eq(:partial)
    expect(unknown.records.first[:oper_status]).to eq(:unknown)
  end

  it "does not interpret a menu or empty section as complete logical inventory" do
    expect(parse("[Layer 3 Menu]\n ip - Show IP information\n").status).to eq(:failed)
    expect(parse(text.lines.reject { |line| line.include?("IP4") }.join).status).to eq(:partial)
  end
end
