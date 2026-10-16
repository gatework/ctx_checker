# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/hillstone/parsers/show_cpu_cntr"
require "ctx_checker/evaluator"

RSpec.describe "Hillstone SG-6000-A3700 CPU port counters" do
  def fixture
    File.read(File.expand_path("fixtures/ctx_checker/hillstone/cpu_cntr_a3700_55r10p14.txt", __dir__))
  end

  def parse(text = fixture, complete: true)
    CtxChecker::Hillstone::Parsers::ShowCpuCntr.parse(text, complete: complete)
  end

  def assess(result)
    observation = CtxChecker::Observation.new(name: :device_counters, **result.to_h.slice(:status, :records, :issues))
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "hillstone" },
      observed_at: Time.utc(2026, 10, 16, 3), observations: { device_counters: observation })
    CtxChecker::Evaluator.new.call(snapshot).findings.select { |finding| finding.dimension == :device_counters }
  end

  it "retains separately identified hardware and queue counts from all four named CPU ports" do
    result = parse
    expect(result).to be_complete
    expect(result.records.size).to eq(184)
    expect(result.records).to include(include(component: "cpu/internal0/28/physical_port_0", metric: "in_bad_pkts",
      category: :error, value: 922, discontinuity: nil))
    expect(result.records).to include(include(component: "cpu/MGT0/physical_port_2/rx_queue_0", metric: "errors", category: :error, value: 0))
    expect(result.records).to include(include(component: "cpu/HA0/physical_port_3/tx_queue_1", metric: "packets", category: :informational, value: 0))
    expect(result.records).to all(include(discontinuity: nil))
  end

  it "never guesses port identities from the joined numeric summary cells" do
    result = parse
    expect(result.records.map { |row| row[:component] }).not_to include(a_string_matching(/port-\d/))
    expect(result.records.map { |row| row[:component] }.uniq.size).to eq(20)
    expect(result.records).not_to include(include(metric: "total_errors"))
  end

  it "reports captured nonzero bad packets as historical warning without claiming a current failure" do
    finding = assess(parse).find { |row| row.entity[:component] == "cpu/internal0/28/physical_port_0" && row.entity[:metric] == "in_bad_pkts" }
    expect(finding.to_h).to include(status: :unknown, reason: :cumulative_errors, actual: 922, severity: :warning)
  end

  it "preserves unclassified drops and collision semantics instead of calling them forwarding faults" do
    result = parse(fixture.sub(/DropEvents:\s+0/, "DropEvents: 99"))
    expect(result).to be_complete
    expect(result.records).to include(include(metric: "drop_events", category: :unknown, value: 99))
    finding = assess(result).find { |row| row.entity[:component] == "cpu/MGT0/physical_port_2" && row.entity[:metric] == "drop_events" }
    expect(finding.to_h).to include(status: :unknown, reason: :counter_category_unavailable)
    expect(result.records.select { |row| row[:metric] == "collisions" }).to all(include(category: :unknown))
  end

  it "does not treat traffic and packet-size distributions as error counters" do
    result = parse
    %w[in_good_octets out_good_pkts in_over1518_pkts pkts64_octets].each do |metric|
      expect(result.records.select { |row| row[:metric] == metric }).to all(include(category: :informational))
    end
    findings = assess(result).select { |row| row.entity[:metric] == "in_good_pkts" }
    expect(findings.map(&:status)).to all(eq(:not_applicable))
  end

  it "keeps missing hardware fields visible without filling them with zero" do
    result = parse(fixture.sub(/InMACRcvErrors:\s+0\s+/, ""))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :cpu_counter_fields_missing, component: "cpu/MGT0/physical_port_2", count: 1))
    expect(result.records).not_to include(include(component: "cpu/MGT0/physical_port_2", metric: "in_mac_rcv_errors"))
    expect(result.records).to include(include(component: "cpu/HA0/physical_port_3", metric: "in_mac_rcv_errors", value: 0))
  end

  it "preserves invalid values as unavailable without losing their valid sibling cell" do
    [ "-1", "NaN", "1,000", "1x" ].each do |value|
      result = parse(fixture.sub(/InBadOctets:\s+0/, "InBadOctets: #{value}"))
      expect(result.status).to eq(:partial)
      expect(result.records).to include(include(component: "cpu/MGT0/physical_port_2", metric: "in_bad_octets", value: nil))
      expect(result.records).to include(include(component: "cpu/MGT0/physical_port_2", metric: "in_good_octets", value: 19_244_375_904))
    end
  end

  it "removes ambiguous duplicate metrics rather than selecting a count" do
    result = parse(fixture.sub("InBadOctets:", "InBadOctets: 77 InBadOctets:"))
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(component: "cpu/MGT0/physical_port_2", metric: "in_bad_octets"))
    expect(result.records).to include(include(component: "cpu/HA0/physical_port_3", metric: "in_bad_octets", value: 0))
  end

  it "preserves unfamiliar named counters with unknown categories and partial coverage" do
    result = parse(fixture.sub("InBadOctets:", "PolicyDropEvents: 44 InBadOctets:"))
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(metric: "policy_drop_events", category: :unknown, value: 44))
    expect(assess(result).find { |row| row.entity[:metric] == "policy_drop_events" }.status).to eq(:unknown)
  end

  it "checks both queue directions and the count declared for each named port" do
    [ fixture.sub("2 RX Queue(s):", "3 RX Queue(s):"),
      fixture.sub(/2 TX Queue\(s\):.*?(?=HA0,)/m, "") ].each do |text|
      result = parse(text)
      expect(result.status).to eq(:partial)
      expect(result.records).to include(include(component: "cpu/internal0/28/physical_port_0", metric: "in_bad_pkts", value: 922))
    end
  end

  it "rejects malformed queue columns without guessing their number boundaries" do
    text = fixture.sub(/0\s+147003490\s+12513240171\s+0/, "0 14700349012513240171 0")
    result = parse(text)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(component: "cpu/MGT0/physical_port_2/rx_queue_0"))
    expect(result.issues).to include(include(code: :cpu_counter_queue_count_mismatch))
  end

  it "removes duplicate queue identities and validates direction-specific headers" do
    [ fixture.sub(/1\s+24276458\s+6731135733\s+0/, "0 24276458 6731135733 0"),
      fixture.sub("In Bytes", "Out Bytes") ].each do |text|
      result = parse(text)
      expect(result.status).to eq(:partial)
      expect(result.records).not_to include(include(component: "cpu/MGT0/physical_port_2/rx_queue_0"))
    end
  end

  it "does not silently accept unrecognized nonnumeric content in the summary or command body" do
    [ fixture.sub("port-4            0", "port-4 unknown"), fixture + "Unexpected footer\n" ].each do |text|
      expect(parse(text).status).to eq(:partial)
    end
  end

  it "keeps empty, rejected, truncated and summary-only evidence unavailable" do
    expect(parse("\n").status).to eq(:failed)
    expect(parse("% Invalid command\n").status).to eq(:unsupported)
    expect(parse(complete: false).status).to eq(:partial)
    expect(parse(fixture.split("MGT0,").first).status).to eq(:failed)
    expect(parse(fixture.split("HA0,").first, complete: false).status).to eq(:partial)
  end
end
