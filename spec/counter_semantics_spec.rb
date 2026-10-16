# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"

RSpec.describe "CtxChecker interface counter measurement semantics" do
  let(:target) { { host: "192.0.2.40", platform: "cisco_ios" } }
  let(:sample_time) { Time.utc(2026, 10, 16, 12) }
  let(:counter) do
    { interface: "GigabitEthernet1/0/1", metric: :out_discards, value: 0,
      unit: :packets, scope: :interface, discontinuity: "verified-counter-epoch" }
  end

  # 构造完整测量记录，不引入命令解析器假设。
  def observation(record, dimension: :counters)
    CtxChecker::Observation.new(name: dimension, status: :complete, records: [ record ])
  end

  # 前次采样使用相同目标及独立递增的采集时间。
  def snapshot(record, at: sample_time, dimension: :counters)
    CtxChecker::Snapshot.new(target: target, observed_at: at,
      observations: { dimension => observation(record, dimension: dimension) })
  end

  # 将包计数策略结果与未请求维度分开验证。
  def assess(record, prior: nil, dimension: :counters)
    previous = snapshot(prior, at: sample_time - 60, dimension: dimension) if prior
    CtxChecker::Evaluator.new.call(snapshot(record, dimension: dimension), previous: previous)
      .findings.find { |finding| finding.dimension == dimension }
  end

  it "validates explicit interface measurement units and scopes without changing legacy records" do
    expect(observation(counter.except(:unit, :scope)).records.first).to include(unit: nil, scope: nil)
    CtxChecker::Observation::COUNTER_UNITS.each do |unit|
      expect(observation(counter.merge(unit: unit)).records.first[:unit]).to eq(unit)
    end
    CtxChecker::Observation::COUNTER_SCOPES.each do |scope|
      expect(observation(counter.merge(scope: scope)).records.first[:scope]).to eq(scope)
    end
    [ { unit: :dbm }, { unit: "packets" }, { unit: 0 }, { scope: "interface" }, { scope: :device } ].each do |invalid|
      expect { observation(counter.merge(invalid)) }.to raise_error(ArgumentError)
    end
    expect do
      observation({ interface: "GigabitEthernet1/0/1", metric: :rx_power, unit: :packets }, dimension: :optics)
    end.to raise_error(ArgumentError)
  end

  it "does not treat a changed measurement scope as a second metric identity" do
    expect do
      CtxChecker::Observation.new(name: :counters, status: :complete,
        records: [ counter, counter.merge(scope: :queue) ])
    end.to raise_error(ArgumentError, /Duplicate/)
  end

  it "defaults declared interface counter sources to packets and preserves explicit parser semantics" do
    parser = CtxChecker::RuntimeParser.new(platform: :cisco_nxos)
    command = "show interface"
    implementation = parser.profile.parser_for(:counters, command: command)
    rows = [ counter.except(:unit, :scope), counter.merge(metric: :in_discards, unit: :unknown, scope: :queue) ]
    allow(implementation).to receive(:parse).and_return(CtxParser::Result.new(status: :complete, records: rows))

    result = parser.parse(:counters, "synthetic body", complete: true, command: command)

    expect(result.records.first).to include(unit: :packets, scope: :interface, source_command: command)
    expect(result.records.last).to include(unit: :unknown, scope: :queue, source_command: command)
  end

  it "does not certify unknown or nonpacket measurements even when their cumulative value is zero" do
    { unknown: :counter_unit_unknown, bytes: :counter_unit_not_packets, events: :counter_unit_not_packets }.each do |unit, reason|
      [ 0, 4 ].each do |value|
        result = assess(counter.merge(unit: unit, value: value))
        expect(result).to have_attributes(status: :unknown, reason: reason)
        expect(result.actual).to include(value: value, unit: unit)
      end
    end
  end

  it "does not calculate packet deltas for bytes events or an unresolved unit" do
    %i[bytes events unknown].each do |unit|
      prior = counter.merge(unit: unit, value: 1)
      result = assess(prior.merge(value: 3), prior: prior)
      expect(result.status).to eq(:unknown)
      expect(result.actual).not_to have_key(:delta)
    end
  end

  it "requires a known measurement scope before applying packet limits" do
    current = counter.merge(scope: :unknown)
    expect(assess(current)).to have_attributes(status: :unknown, reason: :counter_scope_unknown)
    expect(assess(current.merge(value: 2), prior: current)).to have_attributes(status: :unknown, reason: :counter_scope_unknown)
  end

  it "requires unchanged units and scope across samples including the legacy transition" do
    [ nil, :bytes, :events, :unknown ].each do |old_unit|
      result = assess(counter.merge(value: 2), prior: counter.merge(unit: old_unit))
      expect(result).to have_attributes(status: :unknown, reason: :counter_unit_changed)
      expect(result.actual).not_to have_key(:delta)
    end
    [ nil, :queue, :mac, :cpu, :logical, :unknown ].each do |old_scope|
      result = assess(counter.merge(value: 2), prior: counter.merge(scope: old_scope))
      expect(result).to have_attributes(status: :unknown, reason: :counter_scope_changed)
    end
    legacy = counter.except(:unit, :scope)
    expect(assess(legacy, prior: counter)).to have_attributes(status: :unknown, reason: :counter_unit_changed)
  end

  it "retains packet deltas within a known unchanged scope and the existing legacy API" do
    [ nil, :interface, :mac, :cpu, :logical, :queue ].each do |scope|
      previous = counter.merge(scope: scope)
      result = assess(previous.merge(value: 2), prior: previous)
      expect(result).to have_attributes(status: :fail, reason: :counter_delta, actual: { delta: 2, seconds: 60.0 })
    end
    legacy = counter.except(:unit, :scope)
    expect(assess(legacy)).to have_attributes(status: :pass, reason: :zero_cumulative_counter)
    expect(assess(legacy.merge(value: 2), prior: legacy)).to have_attributes(status: :fail, reason: :counter_delta)
  end

  it "keeps the separate device counter policy and continuity contract" do
    row = { component: "dataplane", metric: "packet_parse_error", category: :error,
      value: 0, discontinuity: "verified-counter-epoch" }
    expect(assess(row, dimension: :device_counters)).to have_attributes(status: :pass, reason: :zero_cumulative_counter)
    result = assess(row.merge(value: 3), prior: row, dimension: :device_counters)
    expect(result).to have_attributes(status: :fail, reason: :counter_delta,
      actual: { cumulative: 3, delta: 3, seconds: 60.0, per_second: 0.05 })
  end
end
