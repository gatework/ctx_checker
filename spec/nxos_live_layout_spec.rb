# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"

# 基于 2026-10-16 采集布局精简并匿名化，数值使用合成数据。
RSpec.describe "NX-OS live command layouts" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :cisco_nxos) }
  let(:traffic) { File.read(File.expand_path("fixtures/ctx_checker/cisco_nxos/device_counters_n9k_live_layout.txt", __dir__)) }

  def parse(name, text, complete: true)
    parser.parse(name, text, complete: complete)
  end

  it "recognizes aggregation rows attached to the terminal-width separator" do
    text = "#{'-' * 80}Group Port- Type Protocol Member Ports\nChannel\n#{'-' * 80}10 Po10(SD) Eth NONE --\n"
    result = parse(:aggregation, text)
    expect(result).to be_complete
    expect(result.records).to contain_exactly(include(group: "Port-channel10", oper_status: :down, member: nil))
  end

  it "does not discard unexpected content after a table separator" do
    result = parse(:aggregation, "#{'-' * 80}unexpected content\nGroup Port- Type Protocol Member Ports\n10 Po10(SD) Eth NONE --\n")
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :unparsed_row))
  end

  it "preserves an explicit inapplicable transceiver independently of absent optics" do
    result = parse(:optics, "Ethernet1/1\ntransceiver is not applicable\nEthernet1/2\ntransceiver is not present\n")
    expect(result).to be_complete
    expect(result.records.select { |row| row[:interface] == "Ethernet1/1" }).to all(include(applicable: false, present: nil, dom_supported: false, value: nil))
    expect(result.records.select { |row| row[:interface] == "Ethernet1/2" }).to all(include(applicable: nil, present: false))
  end

  it "rejects contradictory optical presence or measurements after inapplicability" do
    prefix = "Ethernet1/1\ntransceiver is not applicable\n"
    [ "transceiver is present\n", "transceiver is not present\n",
      "Measurement High Low High Low\nTx Power 0 dBm 5 dBm -5 dBm 4 dBm -4 dBm\n" ].each do |suffix|
      result = parse(:optics, prefix + suffix)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :contradictory_optical_applicability))
      expect(result.records).to all(include(applicable: nil, source_complete: false))
    end
  end

  it "retains all independently named N9K software-stack counters" do
    result = parse(:device_counters, traffic)
    expect(result).to be_complete
    expect(result.records).to include(
      include(metric: "ingress_option_processing_failed", value: 8, category: :discard),
      include(metric: "ingress_mforward_failed", value: 9, category: :discard),
      include(metric: "ingress_ra_reass_drops", value: 11, category: :discard),
      include(metric: "bad_gateway_mac", value: 0, category: :error))
    expect(result.records.count { |row| row[:metric] == "ingress_option_processing_failed" }).to eq(1)
    expect(result.records.map { |row| row[:value] }).not_to include(999, 13)
  end

  it "keeps ACL policy drops and informational packet counters separate from errors" do
    result = parse(:device_counters, traffic)
    expect(result).to be_complete
    expect(result.records).to include(
      include(metric: "acl_egress_drops", value: 12, category: :policy),
      include(metric: "packets_snooped", value: 7, category: :informational),
      include(metric: "ingress_lisp_encapsulated", value: 10, category: :informational))
  end

  it "rejects conflicting repeated option-processing counters without losing other facts" do
    result = parse(:device_counters, traffic.sub("failed: 8  Ingress", "failed: 17  Ingress"))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :duplicate_identity))
    expect(result.records).not_to include(include(metric: "ingress_option_processing_failed"))
    expect(result.records).to include(include(metric: "ingress_mforward_failed", value: 9))
  end

  it "requires every ACL row when the subsection is declared" do
    result = parse(:device_counters, traffic.sub(/\s+Directed Broadcast - 0\n/, "\n"))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :acl_counter_fields_missing))
    expect(result.records).to include(include(metric: "acl_egress_drops", value: 12))
  end

  it "keeps an empty or duplicated ACL subsection incomplete" do
    empty = traffic.sub(/ACL Filter Drops :.*?(?=Fragmentation)/m, "ACL Filter Drops :\n")
    repeated = traffic.sub("Fragmentation/reassembly:", "ACL Filter Drops :\nIngress - 0\nEgress - 12\nDirected Broadcast - 0\nFragmentation/reassembly:")
    expect(parse(:device_counters, empty).issues).to include(include(code: :acl_counter_fields_missing, count: 3))
    result = parse(:device_counters, repeated)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :duplicate_counter_section, scope: "acl"))
    expect(result.records).not_to include(include(metric: "acl_egress_drops"))
  end

  it "continues to reject duplicates outside the one repeated NX-OS display cell" do
    result = parse(:device_counters, traffic.sub("Bad options: 0", "Bad options: 0\nBad options: 0"))
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(metric: "bad_options"))
    expect(result.issues).to include(include(code: :duplicate_identity))
  end

  it "keeps malformed per-protocol context separate from fragment loss measurements" do
    result = parse(:device_counters, traffic.sub("17 : 13", "17 : invalid"))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :unparsed_counter))
    expect(result.records).to include(include(metric: "fragments_timed_out", value: 0))
  end

  it "retains unknown or malformed extended counters as incomplete evidence" do
    [ traffic.sub("Bad GW MAC 0", "Bad GW MAC -1"), traffic.sub("Ingress lisp drop: 0", "Future drops: 0"),
      traffic.sub("Ingress lisp drop: 0", "Ingress lisp drop: 0invalid") ].each do |text|
      result = parse(:device_counters, text)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :unparsed_counter))
      expect(result.records).to include(include(metric: "bad_version", value: 2))
    end
  end

  it "does not upgrade recognized output received from an incomplete collection" do
    result = parse(:device_counters, traffic, complete: false)
    expect(result.status).to eq(:partial)
    expect(result.records).to all(include(source_complete: false))
  end
end
