# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/radware_alteon/parsers/stats_mp_cpu"
require "ctx_checker/radware_alteon/parsers/stats_mp_mem"
require "ctx_checker/radware_alteon/parsers/stats_sp_allutils"
require "ctx_checker/radware_alteon/parsers/info_sys_temp"
require "ctx_checker/radware_alteon/parsers/info_sys_fan"
require "ctx_checker/radware_alteon/parsers/info_sys_ps"
require "ctx_checker/observation"

RSpec.describe "Radware Alteon 5424 S Perform 32.4.15.0 system captures" do
  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/radware_alteon/#{name}_5424_32415.txt", __dir__))
  end

  def parse(name, text = fixture(name), complete: true)
    klass = { mp_cpu: CtxChecker::RadwareAlteon::Parsers::StatsMpCpu, mp_memory: CtxChecker::RadwareAlteon::Parsers::StatsMpMem,
      sp_allutils: CtxChecker::RadwareAlteon::Parsers::StatsSpAllutils, temperature: CtxChecker::RadwareAlteon::Parsers::InfoSysTemp,
      fan: CtxChecker::RadwareAlteon::Parsers::InfoSysFan, power: CtxChecker::RadwareAlteon::Parsers::InfoSysPs }.fetch(name)
    klass.parse(text, complete: complete)
  end

  it "preserves the three management CPU windows without claiming service processor coverage" do
    result = parse(:mp_cpu)
    expect(result).to be_complete
    expect(result.records.map { |row| row.values_at(:component, :scope, :window_seconds, :utilization) }).to eq([
      [ "MP", "management_plane", 1, 20.0 ], [ "MP", "management_plane", 4, 17.0 ], [ "MP", "management_plane", 64, 13.0 ]
    ])
  end

  it "keeps missing, malformed and duplicate management CPU windows explicit" do
    expect(parse(:mp_cpu, fixture(:mp_cpu).sub(/cpuUtil4Seconds.*\n/, "")).status).to eq(:partial)
    [ "101%", "NaN%", "-1%", "20" ].each do |value|
      result = parse(:mp_cpu, fixture(:mp_cpu).sub("20%", value))
      expect(result.status).to eq(:partial)
      expect(result.records.first[:utilization]).to be_nil
    end
    result = parse(:mp_cpu, fixture(:mp_cpu) + "cpuUtil1Second (time base):90%\n")
    expect(result.status).to eq(:partial)
    expect(result.records.map { |row| row[:window_seconds] }).to eq([ 4, 64 ])
    expect(parse(:mp_cpu, fixture(:mp_cpu).sub("CPU utilization:", "Unknown future header:")).status).to eq(:partial)
  end

  it "uses physical RAM excluding Linux cache while leaving MP virtual and RSS out of utilization" do
    result = parse(:mp_memory)
    expect(result).to be_complete
    expect(result.records.size).to eq(1)
    expect(result.records.first).to include(component: "system", scope: "physical", total_bytes: 32_879_916 * 1024,
      free_bytes: 15_044_068 * 1024, used_bytes: 8_718_816 * 1024, available_bytes: 24_161_100 * 1024, basis: :used_minus_cache)
    expect(result.records.first[:utilization]).to be_within(0.000001).of(8_718_816.fdiv(32_879_916) * 100)
  end

  it "does not infer cache or utilization from incomplete or contradictory RAM measurements" do
    [ fixture(:mp_memory).sub(/Cached \(Linux\).*\n/, ""), fixture(:mp_memory).sub("9117032", "911703200"),
      fixture(:mp_memory).sub("32879916 KB", "0 KB"), fixture(:mp_memory).sub("32879916 KB", "NaN KB"),
      fixture(:mp_memory).sub("32879916 KB", "32879916 unknown"),
      fixture(:mp_memory).sub("32879916 KB", "#{'9' * 307} GB") ].each do |text|
      result = parse(:mp_memory, text)
      expect(result.status).to eq(:partial)
      expect(result.records.first).to include(utilization: nil, basis: :unknown)
    end
  end

  it "rejects duplicate physical memory fields and validates optional process units separately" do
    result = parse(:mp_memory, fixture(:mp_memory) + "Total device: 32879916 KB\n")
    expect(result.status).to eq(:partial)
    expect(result.records.first[:utilization]).to be_nil
    result = parse(:mp_memory, fixture(:mp_memory).sub("2886.934 MB", "2886.934 mystery"))
    expect(result.status).to eq(:partial)
    expect(result.records.first[:basis]).to eq(:used_minus_cache)
    expect(parse(:mp_memory, fixture(:mp_memory).lines.reject { |line| line.start_with?("MP ") }.join)).to be_complete
  end

  it "preserves each service processor in both CPU windows and the independent memory table" do
    result = parse(:sp_allutils)
    expect(result).to be_complete
    expect(result.fetch(:cpu).records.size).to eq(22)
    expect(result.fetch(:cpu).records.first).to include(component: "SP1", scope: "service_plane", window_seconds: 4, utilization: 2)
    expect(result.fetch(:cpu).records.last).to include(component: "SP11", window_seconds: 64)
    expect(result.fetch(:memory).records.size).to eq(11)
    expect(result.fetch(:memory).records).to all(include(scope: "service_plane", utilization: 1, basis: :used_total))
  end

  it "isolates malformed memory readings from complete service CPU windows" do
    text = fixture(:sp_allutils).sub("SPs memory percentage:\n\nSP  1 : [#.................................................] 1%",
      "SPs memory percentage:\n\nSP  1 : [#.................................................] 101%")
    result = parse(:sp_allutils, text)
    expect(result.fetch(:cpu)).to be_complete
    expect(result.fetch(:memory).status).to eq(:partial)
    expect(result.fetch(:memory).records.first[:utilization]).to be_nil
  end

  it "detects truncated SP sections, mismatched totals and duplicate section identities" do
    text = fixture(:sp_allutils)
    result = parse(:sp_allutils, text.split("SPs memory percentage:").first)
    expect(result.fetch(:cpu)).to be_complete
    expect(result.fetch(:memory).status).to eq(:failed)
    result = parse(:sp_allutils, text.sub("total 11 sp's", "total 12 sp's"))
    expect(result.fetch(:cpu).status).to eq(:partial)
    expect(result.fetch(:memory)).to be_complete
    result = parse(:sp_allutils, text.sub("SP  2 :", "SP  1 :"))
    expect(result.fetch(:cpu).status).to eq(:partial)
    expect(result.fetch(:cpu).records).not_to include(include(component: "SP1", window_seconds: 4))
    result = parse(:sp_allutils, text.sub("for 64 sec", "for 4 sec"))
    expect(result.fetch(:cpu).status).to eq(:partial)
    expect(result.fetch(:memory)).to be_complete
  end

  it "requires summary graph agreement and retains unknown SP rows as diagnostics" do
    result = parse(:sp_allutils, fixture(:sp_allutils).sub("Average : 2%", "Average : 99%"))
    expect(result.fetch(:cpu).status).to eq(:partial)
    expect(result.fetch(:memory)).to be_complete
    expect(parse(:sp_allutils, fixture(:sp_allutils) + "Future memory metric: 10\n").fetch(:memory).status).to eq(:partial)
  end

  it "takes temperature thresholds from the measured command and retains inclusive critical semantics" do
    result = parse(:temperature)
    expect(result).to be_complete
    expect(result.records.map { |row| row[:value] }).to eq([ 46, 27, 34, 31 ])
    expect(result.records).to all(include(high_warning: 79, high_alarm: 88, high_comparison: :gte, status: :unknown))
  end

  it "does not infer thresholds when absent, inconsistent or duplicated" do
    text = fixture(:temperature)
    result = parse(:temperature, text.split("Note:").first)
    expect(result).to be_complete
    expect(result.records).to all(include(status: :unknown))
    expect(result.records).not_to include(include(high_alarm: 88))
    [ text.sub("Critical temperature 88 and above", "Critical temperature 90 and above"),
      text + "Critical temperature 88 and above degree Celsius\n" ].each do |sample|
      result = parse(:temperature, sample)
      expect(result.status).to eq(:partial)
      expect(result.records).not_to include(include(high_alarm: 88))
    end
  end

  it "preserves explicit thermal faults and reports normal-summary disagreement" do
    result = parse(:temperature, fixture(:temperature).sub("has 46", "has 88"))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :temperature_state_disagreement))
    expect(result.records.first).to include(value: 88, high_alarm: 88)
    result = parse(:temperature, fixture(:temperature).sub("temperature is OK", "temperature is Critical"))
    expect(result.records).to include(include(component: "device_temperature", status: :critical))
    expect(parse(:temperature, fixture(:temperature).sub("has 46", "has NaN")).status).to eq(:partial)
    expect(parse(:temperature, fixture(:temperature) + "Sensor 1 has 90 degree Celsius\n").records).not_to include(include(component: "sensor1"))
  end

  it "uses explicit fan criticality and does not infer failure severity from fan position" do
    result = parse(:fan)
    expect(result).to be_complete
    expect(result.records).to eq([
      { component: "fan1", kind: :fan, status: :ok }, { component: "fan2", kind: :fan, status: :ok }
    ])
    text = fixture(:fan).sub(/1\s+Critical\s+Operational\s+36%/, "1 Critical Failed 0%")
      .sub(/2\s+Critical\s+Operational\s+36%/, "2 Non-critical Failed 0%")
    expect(parse(:fan, text).records).to include(include(component: "fan1", status: :critical), include(component: "fan2", status: :warning))
  end

  it "keeps unknown, contradictory or duplicate fan data unavailable" do
    [ fixture(:fan).sub("Operational", "Unexpected"), fixture(:fan).sub("36%", "0%"),
      fixture(:fan).sub("36%", "101%"), fixture(:fan).sub("Fans table:", "") ].each do |text|
      expect(parse(:fan, text).status).to eq(:partial)
    end
    result = parse(:fan, fixture(:fan) + "1 Critical Failed 0%\n")
    expect(result.records.map { |row| row[:component] }).to eq([ "fan2" ])
  end

  it "reports the power arrangement without inventing per-PSU presence" do
    result = parse(:power)
    expect(result).to be_complete
    expect(result.records).to eq([ { component: "dual_power_supply_system", kind: :power_supply, status: :ok, present: nil } ])
    expect(parse(:power, "Single Power Supply Status: OK\n").records.first).to include(component: "single_power_supply_system", status: :ok)
    expect(parse(:power, "Dual Power Supply Status: Failed\n").records.first[:status]).to eq(:failed)
    expect(parse(:power, "Dual Power Supply Status: Future\n").status).to eq(:partial)
    expect(parse(:power, fixture(:power) + "Single Power Supply Status: OK\n").status).to eq(:failed)
  end

  it "satisfies canonical schemas and retains command-level failures and transport incompleteness" do
    { mp_cpu: :cpu, mp_memory: :memory, temperature: :temperature, fan: :environment, power: :power }.each do |name, dimension|
      result = parse(name)
      expect { CtxChecker::Observation.new(name: dimension, **result.to_h.slice(:status, :records, :issues)) }.not_to raise_error
    end
    parse(:sp_allutils).by_dimension.each do |dimension, result|
      expect { CtxChecker::Observation.new(name: dimension, **result.to_h.slice(:status, :records, :issues)) }.not_to raise_error
    end
    %i[mp_cpu mp_memory sp_allutils temperature fan power].each do |name|
      expect(parse(name, complete: false).status).to eq(:partial)
      expect(parse(name, "\n").status).to eq(:failed)
      expect(parse(name, "Invalid command\n").status).to eq(:unsupported)
    end
  end
end
