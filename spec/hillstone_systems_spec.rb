# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/hillstone/parsers/show_cpu"
require "ctx_checker/hillstone/parsers/show_memory"
require "ctx_checker/hillstone/parsers/show_environment"
require "ctx_checker/observation"

RSpec.describe "Hillstone SG-6000-A3700 5.5R10P14 system captures" do
  def fixture(name)
    File.read(File.expand_path("fixtures/ctx_checker/hillstone/#{name}_a3700_55r10p14.txt", __dir__))
  end

  def parse(name, text = fixture(name), complete: true)
    klass = { cpu: CtxChecker::Hillstone::Parsers::ShowCpu, memory: CtxChecker::Hillstone::Parsers::ShowMemory,
      environment: CtxChecker::Hillstone::Parsers::ShowEnvironment }.fetch(name)
    klass.parse(text, complete: complete)
  end

  it "preserves current CPU, named windows and the unspecified overall average separately" do
    result = parse(:cpu)
    expect(result).to be_complete
    expect(result.records.map { |row| row.values_at(:scope, :window_seconds, :utilization) }).to eq([
      [ "system_average", nil, 13.2 ], [ "system", nil, 11.7 ], [ "system", 60, 11.7 ],
      [ "system", 300, 11.2 ], [ "system", 900, 11.1 ]
    ])
    expect { CtxChecker::Observation.new(name: :cpu, **result.to_h.slice(:status, :records, :issues)) }.not_to raise_error
  end

  it "does not manufacture a CPU window when a known sample is missing" do
    result = parse(:cpu, fixture(:cpu).sub("Last 5 minutes :11.2%\n", ""))
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :missing_cpu_windows, count: 1))
    expect(result.records).not_to include(include(window_seconds: 300))
  end

  it "keeps invalid CPU percentages unavailable and never accepts arbitrary extra fields" do
    [ "101%", "-1%", "NaN%", "Infinity%", "11.7" ].each do |value|
      result = parse(:cpu, fixture(:cpu).sub("Current cpu utilization :11.7%", "Current cpu utilization :#{value}"))
      expect(result.status).to eq(:partial)
      expect(result.records).to include(include(scope: "system", window_seconds: nil, utilization: nil))
    end
    expect(parse(:cpu, fixture(:cpu) + "Future cpu load :20%\n").status).to eq(:partial)
  end

  it "removes duplicate CPU identities while preserving unrelated windows" do
    result = parse(:cpu, fixture(:cpu) + "Current cpu utilization :99.0%\n")
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(scope: "system", window_seconds: nil))
    expect(result.records).to include(include(scope: "system", window_seconds: 900, utilization: 11.1))
  end

  it "uses verified current memory totals rather than rounded summary or historical samples" do
    result = parse(:memory)
    expect(result).to be_complete
    expect(result.records.size).to eq(1)
    expect(result.records.first).to include(component: "system", scope: "physical", total_bytes: 16_345_088 * 1024,
      used_bytes: 4_075_191 * 1024, free_bytes: 12_269_897 * 1024, basis: :used_total)
    expect(result.records.first[:utilization]).to be_within(0.000001).of(4_075_191.fdiv(16_345_088) * 100)
    expect { CtxChecker::Observation.new(name: :memory, **result.to_h.slice(:status, :records, :issues)) }.not_to raise_error
  end

  it "allows commands without optional history sections when the current sample is complete" do
    text = fixture(:memory).split("Memory utilization in last").first
    expect(parse(:memory, text)).to be_complete
  end

  it "does not confuse incomplete, duplicated or invalid memory history with current health" do
    [ fixture(:memory).sub(/59 :\s+24\.9\n/, ""),
      fixture(:memory).sub(/59 :\s+24\.9/, "59 : 24.9\n59 : 24.9"),
      fixture(:memory).sub(/59 :\s+24\.9/, "59 : 101.0") ].each do |text|
      result = parse(:memory, text)
      expect(result.status).to eq(:partial)
      expect(result.records.first[:basis]).to eq(:used_total)
    end
  end

  it "rejects missing history labels, unexpected indices and duplicate history sections" do
    text = fixture(:memory)
    [ text.sub("memoryutil", ""), text.sub(/167:/, "168:"),
      text + text.split("Memory utilization in last 60 seconds(%):", 2).last.prepend("Memory utilization in last 60 seconds(%):") ].each do |sample|
      expect(parse(:memory, sample).status).to eq(:partial)
    end
  end

  it "detects output ending at a complete history section before the remaining advertised layout" do
    result = parse(:memory, fixture(:memory).split("Memory utilization in last 60 minutes(%):").first)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :missing_memory_history_sections))
    expect(result.records.first[:basis]).to eq(:used_total)
  end

  it "keeps contradictory current totals or percentage summaries unavailable" do
    [ fixture(:memory).sub("12269897", "12269898"),
      fixture(:memory).sub("utilization: 24%", "utilization: 80%"),
      fixture(:memory).sub("utilization: 24%", "utilization: NaN%") ].each do |text|
      result = parse(:memory, text)
      expect(result.status).to eq(:partial)
      expect(result.records.first).to include(utilization: nil, basis: :unknown)
    end
  end

  it "does not select one of conflicting memory rows or headers" do
    current = fixture(:memory).split("Memory utilization in last").first
    [ current + "1 1 0\n", current + "total(KB) used(KB) free(KB)\n", current + "The percentage of memory utilization: 24%\n" ].each do |text|
      result = parse(:memory, text)
      expect(result.status).to eq(:partial)
      expect(result.records).to be_empty
    end
  end

  it "does not treat unknown units or summary-only memory output as full coverage" do
    [ fixture(:memory).gsub("(KB)", "(MB)"), "The percentage of memory utilization: 24%\n" ].each do |text|
      result = parse(:memory, text)
      expect(result.status).not_to eq(:complete)
      expect(result.records).to be_empty
    end
  end

  it "returns independent temperature, fan and power views from the captured environment command" do
    result = parse(:environment)
    expect(result).to be_complete
    expect(result.fetch(:temperature).records.size).to eq(4)
    expect(result.fetch(:temperature).records.first).to include(component: "CPU", value: 36, low_alarm: 0, high_alarm: 90,
      high_comparison: nil, status: :unknown)
    expect(result.fetch(:environment).records).to all(include(kind: :fan, status: :ok))
    expect(result.fetch(:power).records).to eq([
      { component: "PS0", kind: :power_supply, status: :ok, present: true },
      { component: "PS1", kind: :power_supply, status: :ok, present: true }
    ])
    result.results.each do |dimension, view|
      expect { CtxChecker::Observation.new(name: dimension, **view.to_h.slice(:status, :records, :issues)) }.not_to raise_error
    end
  end

  it "isolates unknown power state and keeps temperature and fans complete" do
    result = parse(:environment, fixture(:environment).sub(/PS1\s+Fine/, "PS1 Unexpected"))
    expect(result.fetch(:power).status).to eq(:partial)
    expect(result.fetch(:power).records.last).to include(status: :unknown, present: nil)
    expect(result.fetch(:temperature)).to be_complete
    expect(result.fetch(:environment)).to be_complete
  end

  it "preserves explicit failed or absent hardware states" do
    text = fixture(:environment).sub(/PS1\s+Fine/, "PS1 Absent").sub(/Fan2\s+Fine/, "Fan2 Fault")
    result = parse(:environment, text)
    expect(result.fetch(:power).records.last).to include(status: :absent, present: false)
    expect(result.fetch(:environment).records).to include(include(component: "Fan2", status: :failed))
  end

  it "keeps invalid temperature measurements or ranges separate from unaffected hardware" do
    [ "CPU 36 90-0", "CPU NaN 0-90", "CPU unavailable 0-90" ].each do |line|
      result = parse(:environment, fixture(:environment).sub(/CPU\s+36\s+0-90/, line))
      expect(result.fetch(:temperature).status).to eq(:partial)
      expect(result.fetch(:temperature).records.first[:value]).to be_nil
      expect(result.fetch(:environment)).to be_complete
      expect(result.fetch(:power)).to be_complete
    end
  end

  it "does not accept missing environment sections, headers or rows as healthy coverage" do
    [ fixture(:environment).split("Power information:").first,
      fixture(:environment).sub(/PS[01]\s+Fine\n/, "").sub(/PS[01]\s+Fine\n/, ""),
      fixture(:environment).sub(/Power information:.*?Description\s+Status/m, "Power information:") ].each do |text|
      result = parse(:environment, text)
      expect(result.fetch(:power).status).not_to eq(:complete)
      expect(result.fetch(:temperature)).to be_complete
    end
  end

  it "removes duplicate hardware identities and reports unknown sections" do
    result = parse(:environment, fixture(:environment) + "PS1 Fine\n")
    expect(result.fetch(:power).status).to eq(:partial)
    expect(result.fetch(:power).records.map { |row| row[:component] }).to eq([ "PS0" ])
    result = parse(:environment, fixture(:environment) + "Future information:\nValue 1\n")
    expect(result.results.values).to all(have_attributes(status: :partial))
  end

  it "preserves transport incompleteness, empty output and command rejection" do
    %i[cpu memory environment].each do |name|
      result = parse(name, complete: false)
      expect(result.status).to eq(:partial)
      expect(result.issues).to include(include(code: :incomplete_output))
      expect(parse(name, "\n").status).to eq(:failed)
      expect(parse(name, "% Invalid command\n").status).to eq(:unsupported)
    end
  end
end
