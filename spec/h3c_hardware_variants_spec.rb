# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"
require "ctx_checker/evaluator"

RSpec.describe "H3C hardware layout and population variants" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :h3c) }

  def parse(name, text)
    parser.parse(name, text, complete: true)
  end

  def report(name, observation, policy: CtxChecker::Policy.new)
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "h3c" },
      observed_at: Time.now.utc, observations: { name => observation })
    CtxChecker::Evaluator.new(policy: policy).call(snapshot)
  end

  it "uses hotspot identifiers across the Sensor and Name header variants without hardcoding hardware labels" do
    %w[Sensor Name].each do |label|
      text = <<~OUTPUT
        System temperature information (degree centigrade):
        Slot Hotspot #{label} Temperature Lower Warning Alarm Shutdown
        1 hotspot1 MAC 43 0 99 102 107
        1 hotspot2 PHY 41 0 112 117 NA
        1 hotspot3 Optmod 21 NA NA NA NA
        2 hotspot1 LM75 24 0 76 85 NA
      OUTPUT
      result = parse(:temperature, text)
      expect(result).to be_complete
      expect(result.records.map { |row| row[:component] }).to eq([ "slot 1/hotspot 1", "slot 1/hotspot 2", "slot 1/hotspot 3", "slot 2/hotspot 1" ])
      expect(result.records.first).to include(value: 43, low_warning: 0, high_warning: 99, high_alarm: 102)
      expect(result.records[2]).to include(value: 21, low_warning: nil, high_warning: nil, high_alarm: nil)
      expect(report(:temperature, result).findings.select { |row| row.entity && row.entity[:component] == "slot 1/hotspot 3" })
        .to all(have_attributes(status: :unknown))
      expect(parse(:temperature, text.sub("43 0 99 102 107", "43 0 99 102")).status).to eq(:partial)
    end
  end

  it "retains unavailable subcard readings and quarantines duplicate hotspot identities" do
    prefix = "Slot Hotspot Sensor Temperature Lower Warning Alarm Shutdown\n"
    text = prefix + "1 hotspot5 Subcard 1-1 -- NA NA NA NA\n1 hotspot6 Subcard 2-1 NA NA NA NA NA\n"
    result = parse(:temperature, text)
    expect(result.status).to eq(:partial)
    expect(result.records.size).to eq(2)
    expect(result.records).to all(include(value: nil, high_warning: nil, high_alarm: nil))
    expect(result.issues).to all(include(code: :missing_temperature_measurement))
    duplicate = parse(:temperature, prefix + "1 hotspot1 MAC 43 0 99 102 107\n1 hotspot1 PHY 41 0 112 117 NA\n")
    expect(duplicate.status).to eq(:partial)
    expect(duplicate.issues).to include(include(code: :duplicate_identity))
    expect(duplicate.records).to be_empty
    expect(parse(:temperature, prefix + "1 hotspot1 MAC 43 0 99 102 107 unexpected\n").status).to eq(:failed)
  end

  it "reads the declared power switch column while preserving each slot and actual watts" do
    text = [ 1, 2 ].map do |slot|
      <<~OUTPUT
        Slot #{slot}:
        Input Power: --
        PowerID State Mode Current(A) Voltage(V) Power(W) FanDirection Switch
        1 Normal AC 1.1 55.4 62.5 -- on
        2 Normal AC 1.0 55.4 54.3 -- on
      OUTPUT
    end.join
    result = parse(:power, text)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:component] }).to eq([ "slot 1/power 1", "slot 1/power 2", "slot 2/power 1", "slot 2/power 2" ])
    expect(result.records).to all(include(status: :ok, present: true))
    expect(result.records.map { |row| row[:watts] }).to eq([ 62.5, 54.3, 62.5, 54.3 ])
    expect(report(:power, result).counts[:pass]).to eq(4)

    [ text.sub(" Switch", ""), text.sub("-- on", "--"), text.sub("-- on", "-- on extra"),
      text.sub("Input Power: --", "Input Power: 100") ].each do |invalid|
      expect(parse(:power, invalid).status).to eq(:partial)
    end
  end

  it "does not promote an off or unknown power switch to a healthy supply" do
    prefix = "Slot 1:\nPowerID State Mode Current(A) Voltage(V) Power(W) FanDirection Switch\n"
    %w[off -- unexpected].each do |switch|
      result = parse(:power, prefix + "1 Normal AC 1.1 55.4 62.5 -- #{switch}\n")
      expect(result.status).to eq(:partial)
      expect(result.records.first).to include(status: :unknown, watts: 62.5)
      expect(result.issues).to include(include(code: :power_switch_not_on))
      expect(report(:power, result).findings.select { |row| row.dimension == :power }).to all(have_attributes(status: :unknown))
    end
  end

  it "reports scoped fanless hardware as absent and inapplicable without inventing a numbered fan" do
    result = parse(:environment, " Slot 1:\nFan-less\n")
    expect(result).to be_complete
    expect(result.issues).to be_empty
    expect(result.records).to contain_exactly(include(component: "slot 1/fan", kind: :fan, status: :absent))
    expect(report(:environment, result).findings.select { |row| row.dimension == :environment })
      .to all(have_attributes(status: :not_applicable, reason: :hardware_absent))
    policy = CtxChecker::Policy.new(required_components: { environment: [ "slot 1/fan" ] })
    expect(report(:environment, result, policy: policy).findings.select { |row| row.dimension == :environment })
      .to all(have_attributes(status: :fail, reason: :hardware_absent))
    numbered = CtxChecker::Policy.new(required_components: { environment: [ "slot 1/fan 1" ] })
    expect(report(:environment, result, policy: numbered).findings)
      .to include(have_attributes(status: :fail, reason: :required_component_missing))
  end

  it "keeps contradictory duplicate and unscoped fanless declarations unresolved" do
    [ "Slot 1:\nFan-less\nFan 1 State: Normal\n", "Slot 1:\nFan-less\nSlot 1:\nFan 1 State: Normal\n" ].each do |text|
      result = parse(:environment, text)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :conflicting_fan_presence))
      expect(result.records.find { |row| row[:component] == "slot 1/fan" }[:status]).to eq(:unknown)
      expect(report(:environment, result).counts[:pass]).to eq(0)
    end
    duplicate = parse(:environment, "Slot 1:\nFan-less\nFan-less\n")
    expect(duplicate.status).to eq(:partial)
    expect(duplicate.records).to be_empty
    expect(duplicate.issues).to include(include(code: :duplicate_identity))
    expect(parse(:environment, "Fan-less\n").status).to eq(:failed)
    expect(parse(:environment, "Slot 1:\nFan-less historical state\n").status).to eq(:failed)
  end
end
