# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"

RSpec.describe "NX-OS system command variants" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :cisco_nxos) }

  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/cisco_nxos/#{name}.txt", __dir__))
  end

  def parse(name, text)
    parser.parse(name, text, complete: true)
  end

  it "distinguishes power output, input and capacity in Nexus 9508 tables" do
    result = parse(:power, fixture(:environment_n9508))
    expect(result).to be_complete
    expect(result.records).to include(include(component: "power supply 1", watts: 510, capacity_watts: 3000, status: :ok))
    expect(result.records).to include(include(component: "power supply 2", watts: nil, capacity_watts: 0, status: :absent, present: false))
    expect(result.records).to include(include(component: "power supply 4", watts: 0, capacity_watts: 3000, status: :critical))
  end

  it "keeps module N/A readings and fan shutdown states without swallowing the next section" do
    result = parse(:environment, fixture(:environment_n9508))
    expect(result).to be_complete
    expect(result.records).to include(include(component: "module 28", status: :ok))
    expect(result.records).to include(include(component: "fan Fan_in_PS4", status: :critical))
    expect(result.records).to include(include(component: "fan Fan_in_PS2", status: :unknown))
    expect(result.records).to include(include(component: "fan air filter", status: :absent))
  end

  it "does not treat unknown fan status words or amps as healthy power readings" do
    text = fixture(:environment_n9508).sub(/front-to-back\s+Shutdown/, "front-to-back Surprise")
    result = parse(:environment, text)
    expect(result.records).to include(include(component: "fan Fan_in_PS4", status: :unknown))
    text = "Power Supply:\nSupply Model Output Capacity Status\n1 TEST 100 A 500 A Ok\n"
    expect(parse(:power, text).status).not_to eq(:complete)
    expect(parse(:power, text).records).to be_empty
  end

  it "retains N9508 temperature thresholds while independently handling power variants" do
    result = parse(:temperature, fixture(:environment_n9508))
    expect(result).to be_complete
    expect(result.records.first).to include(component: "1/Intake (s1)", value: 28, high_alarm: 60, high_warning: 45)
  end

  it "does not promote input watts to capacity when a three-column power row is incomplete" do
    text = fixture(:environment_n9508).sub("3000 W   Ok", "broken W Ok")
    result = parse(:power, text)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(component: "power supply 1"))
    expect(result.records).to include(include(component: "power supply 4", status: :critical))
    text = fixture(:environment_n9508).sub("560 W", "-560 W")
    result = parse(:power, text)
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(component: "power supply 1", watts: 510, capacity_watts: 3000))
  end

  it "uses the documented one second CPU window for aggregate and per-core readings" do
    result = parse(:cpu, fixture(:resources_n9k))
    expect(result).to be_complete
    expect(result.records.map { |row| row[:window_seconds] }.uniq).to eq([ 1 ])
    expect(result.records.map { |row| row[:utilization] }).to eq([ 12.7, 7.22, 15.31 ])
  end

  it "does not infer a missing cache half or use a duplicated cache reading" do
    text = "Memory usage: 1000K total, 800K used, 200K free\nKernel buffers: 100K Used\n"
    result = parse(:memory, text)
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(used_bytes: 819_200, available_bytes: nil, basis: :used_including_cache)
    text += "Kernel cached: 100K Used\nKernel cached: 200K Used\n"
    result = parse(:memory, text)
    expect(result.status).to eq(:partial)
    expect(result.records.first).to include(used_bytes: 819_200, available_bytes: nil, basis: :used_including_cache)
  end

  it "keeps memory units explicit and a broken memory sample isolated from CPU" do
    text = fixture(:resources_n9k).sub("2000000K total", "2000000 total")
    expect(parse(:memory, text).status).to eq(:failed)
    expect(parse(:cpu, text)).to be_complete
    expect(parse(:memory, fixture(:resources_n9k)).records.first).to include(total_bytes: 2_048_000_000)
  end

  it "retains Nexus 5500 optional counters without classifying recovery counts as errors" do
    result = parse(:device_counters, fixture(:device_counters_n5500))
    expect(result).to be_complete
    expect(result.records).to include(include(metric: "stateful_restart_recovery", value: 8, category: :informational))
    expect(result.records).to include(include(metric: "mbuf_pullup_failed", value: 2, category: :discard))
    expect(result.records).to include(include(metric: "fragments_dropped", value: 3, category: :discard))
    expect(result.records).to include(include(metric: "fragments_timed_out", value: 4, category: :discard))
    expect(result.records).not_to include(include(value: 999))
  end

  it "rejects new malformed or duplicated counters without removing unrelated metrics" do
    text = fixture(:device_counters_n5500)
    result = parse(:device_counters, text.sub("MBUF pull up fail: 2", "MBUF pull up fail: -2"))
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(metric: "checksum_errors", value: 1))
    text = text.sub("MBUF pull up fail: 2", "MBUF pull up fail: 2\nMBUF pull up fail: 3")
    result = parse(:device_counters, text)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(metric: "mbuf_pullup_failed"))
  end

  it "requires both fragment loss counters once their section is announced" do
    text = fixture(:device_counters_n5500)
    empty = text.sub(/Fragmentation\/reassembly:.*?(?=ICMP)/m, "Fragmentation/reassembly:\n")
    context_only = text.sub(/Fragments dropped:.*?\n/, "").sub(/Fragments timed out:.*?\n/, "")
    missing_timeout = text.sub(/Fragments timed out:.*?\n/, "")
    [ empty, context_only, missing_timeout ].each do |sample|
      result = parse(:device_counters, sample)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :fragment_counter_fields_missing))
      expect(result.records).to include(include(metric: "checksum_errors", value: 1))
    end
    invalid = text.sub("Fragments timed out: 4", "Fragments timed out: invalid")
    expect(parse(:device_counters, invalid).status).to eq(:partial)
  end
end
