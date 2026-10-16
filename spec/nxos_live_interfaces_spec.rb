# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"

# 合成语法用例采用 Cisco 文档字段；部分现场回显不能视为完整证据。
RSpec.describe "NX-OS live interface grammar" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :cisco_nxos) }
  let(:physical) { "Ethernet1/1 is up\nadmin state is up, Dedicated Interface\n0 input error\n0 output error\n3 CRC\n2 Stomped CRC\n" }

  it "keeps stomped CRC as an independent subset without adding it to total CRC" do
    result = parser.parse(:counters, physical, complete: true)
    expect(result).to be_complete
    expect(result.records).to include(include(metric: :crc_errors, value: 3), include(metric: :stomped_crc_errors, value: 2))
    expect(CtxChecker::Policy.new(counter_limits: { stomped_crc_errors: 1 }).counter_limits).to eq(stomped_crc_errors: 1)
  end

  it "reads adjacent regular and stomped CRC fields without confusing their labels" do
    text = physical.sub("3 CRC\n2 Stomped CRC", "3 CRC  2 Stomped   CRC  0 no buffer")
    result = parser.parse(:counters, text, complete: true)
    expect(result).to be_complete
    expect(result.records).to include(include(metric: :crc_errors, value: 3), include(metric: :stomped_crc_errors, value: 2))
  end

  it "keeps malformed and duplicated stomped counters visible without deleting total CRC" do
    [ "-1 Stomped CRC", "invalid Stomped CRC", "2 Stomped CRC\n3 Stomped CRC" ].each do |cell|
      result = parser.parse(:counters, physical.sub("2 Stomped CRC", cell), complete: true)
      expect(result.status).to eq(:partial)
      expect(result.records).to include(include(metric: :crc_errors, value: 3))
      expect(result.records).not_to include(include(metric: :stomped_crc_errors))
    end
  end

  it "does not require the newer stomped counter on versions that omit it" do
    result = parser.parse(:counters, physical.sub("2 Stomped CRC\n", ""), complete: true)
    expect(result).to be_complete
    expect(result.records).not_to include(include(metric: :stomped_crc_errors))
  end

  it "does not mistake stomped CRC for the mandatory total CRC field" do
    result = parser.parse(:counters, physical.sub("3 CRC\n", ""), complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :counter_fields_missing, metrics: [ :crc_errors ]))
    expect(result.records).to include(include(metric: :stomped_crc_errors, value: 2))
  end

  it "retains interrupted collection status even when every supplied line is recognized" do
    results = parser.parse_many(%i[interfaces counters], physical, complete: false)
    expect(results.values.map(&:status)).to eq(%i[partial partial])
    expect(results.values.flat_map(&:records)).to all(include(source_complete: false))
  end

  it "accepts management connector metadata without inventing missing error counters" do
    text = "mgmt0 is up\nadmin state is up,\n0 broadcast packets 12 bytes\nManagement transceiver: Absent\nActive connector: RJ45\n"
    results = parser.parse_many(%i[interfaces counters], text, complete: true)
    expect(results[:interfaces]).to be_complete
    expect(results[:counters]).to be_complete
    expect(results[:counters].records.size).to eq(3)
    expect(results[:counters].records).to all(include(interface: "mgmt0", value: nil))
  end

  it "requires complete management metadata and never suppresses a partial error report" do
    header = "mgmt0 is up\nadmin state is up,\n"
    metadata = "Management transceiver: Absent\nActive connector: RJ45\n"
    [ header, header + "Management transceiver: Absent\n", header + "0 input errors\n" + metadata,
      header + "invalid input errors\n" + metadata, header + metadata + metadata ].each do |text|
      result = parser.parse(:counters, text, complete: true)
      expect(result.status).not_to eq(:complete)
    end
    result = parser.parse(:counters, header + metadata, complete: false)
    expect(result.status).to eq(:partial)
    expect(result.records).to all(include(source_complete: false))
  end

  it "does not apply the management counter exception to ordinary Ethernet ports" do
    text = "Ethernet1/1 is up\nManagement transceiver: Absent\nActive connector: RJ45\n"
    result = parser.parse(:counters, text, complete: true)
    expect(result.status).not_to eq(:complete)
    expect(result.issues).to include(include(code: :counter_fields_missing, interface: "Ethernet1/1"))
  end

  it "preserves loopback carrier errors separately from output errors" do
    text = "loopback1 is up\nadmin state is up,\n0 multicast frames 0 compressed\n4 output errors\n3 out_carrier_errors\n"
    results = parser.parse_many(%i[interfaces counters], text, complete: true)
    expect(results.values).to all(be_complete)
    expect(results[:counters].records).to include(include(metric: :out_errors, value: 4), include(metric: :out_carrier_errors, value: 3))
    expect(results[:interfaces].records.first).to include(protocol_status: :unknown)
  end

  it "keeps unrecognized management connector status metadata incomplete" do
    result = parser.parse(:interfaces, "mgmt0 is up\nManagement transceiver: Surprise\n", complete: true)
    expect(result.status).to eq(:partial)
  end

  it "preserves the IOS grammar when an NX-OS-only counter label is supplied" do
    result = CtxChecker::RuntimeParser.new(platform: :cisco_ios).parse(:counters, physical, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(metric: :stomped_crc_errors))
  end
end
