# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Reviewed evidence boundaries" do
  def evaluate(observation, policy: CtxChecker::Policy.new)
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "cisco_ios" },
      observed_at: Time.utc(2026, 10, 17), observations: { observation.name => observation })
    CtxChecker::Evaluator.new(policy: policy).call(snapshot)
  end

  it "requires a temperature reading for an explicit sensor threshold" do
    policy = CtxChecker::Policy.new(temperature_thresholds: { "inlet" => { high_warning: 50 } })
    observation = CtxChecker::Observation.new(name: :temperature, status: :complete,
      records: [ { component: "inlet", status: :ok } ])
    report = evaluate(observation, policy: policy)
    expect(report).not_to be_healthy
    expect(report.findings).to include(have_attributes(status: :unknown, reason: :temperature_value_unavailable))
    expect(evaluate(observation)).to be_healthy
    alarm = CtxChecker::Observation.new(name: :temperature, status: :complete,
      records: [ { component: "inlet", status: :critical } ])
    expect(evaluate(alarm, policy: policy).status).to eq(:fail)
  end

  it "matches integer OSPF process selectors to parsed text identities" do
    output = "OSPF Process ID 1 VRF default\nNeighbor ID Pri State Dead Time Address Interface\n192.0.2.2 1 FULL/DR 00:00:30 192.0.2.2 Gi1/0/1\n"
    observation = CtxChecker::RuntimeParser.new(platform: :cisco_ios).parse(:ospf, output, complete: true)
    identity = { vrf: "default", process_id: 1, interface: "GigabitEthernet1/0/1", router_id: "192.0.2.2" }
    policy = CtxChecker::Policy.new(expected_ospf: [ identity ])
    expect(evaluate(observation, policy: policy)).to be_healthy
    expect(identity[:process_id]).to eq(1)
    expect do
      CtxChecker::Policy.new(expected_ospf: [ identity, identity.merge(process_id: "1") ])
    end.to raise_error(ArgumentError)
  end

  it "normalizes manually constructed OSPF records and coverage scopes together" do
    identity = { vrf: "default", process_id: 1, interface: "GigabitEthernet1/0/1", router_id: "192.0.2.2" }
    observation = CtxChecker::Observation.new(name: :ospf, status: :complete,
      records: [ identity.merge(state: :full) ], covered_scopes: [ { vrf: "default", process_id: 1 } ])
    expect(observation.records.first[:process_id]).to eq("1")
    expect(observation.covered_scopes.first[:process_id]).to eq("1")
    expect(evaluate(observation, policy: CtxChecker::Policy.new(expected_ospf: [ identity.merge(process_id: "1") ]))).to be_healthy
    expect do
      CtxChecker::Observation.new(name: :ospf, status: :complete,
        records: [ identity, identity.merge(process_id: "1") ])
    end.to raise_error(ArgumentError, /Duplicate/)
    expect do
      CtxChecker::Observation.new(name: :ospf, status: :complete,
        covered_scopes: [ { vrf: "default", process_id: 1 }, { vrf: "default", process_id: "1" } ])
    end.to raise_error(ArgumentError, /unique/)
  end

  it "preserves conflicting Cisco protocol states regardless of line order" do
    %i[cisco_ios cisco_nxos].each do |platform|
      parser = CtxChecker::RuntimeParser.new(platform: platform)
      %w[up down].permutation.each do |first, last|
        output = "Ethernet1/1 is up, line protocol is #{first}\nLine protocol is #{last}\n"
        observation = parser.parse(:interfaces, output, complete: true)
        expect(observation.status).to eq(:partial)
        expect(observation.issues).to include(include(code: :conflicting_interface_state, field: :protocol_status))
        expect(evaluate(observation).status).to eq(:fail)
      end
    end
  end

  it "keeps explicit Cisco administrative contradictions from becoming an exemption" do
    parser = CtxChecker::RuntimeParser.new(platform: :cisco_nxos)
    observation = parser.parse(:interfaces, "Ethernet1/1 is down\nadmin state is up\nadmin state is down\n", complete: true)
    expect(observation.status).to eq(:partial)
    expect(observation.issues).to include(include(code: :conflicting_interface_state, field: :admin_status))
    expect(evaluate(observation).status).to eq(:fail)
  end

  it "bounds diagnostic samples while retaining failure and omitted counts" do
    parser = CtxChecker::RuntimeParser.new(platform: :cisco_ios)
    [ "Error:\n", "unexpected row\n", "--More--\n" ].each do |line|
      observation = parser.parse(:clock, line * 10_000, complete: true)
      expect(observation).not_to be_complete
      expect(observation.issues.size).to be <= 129
      expect(observation.issues).to include(include(code: :diagnostics_truncated, count: be >= 9_872))
    end
    observation = parser.parse(:interfaces, ("--More--\n" * 1_000) + "Error: failed\n", complete: true)
    expect(observation.status).to eq(:failed)
  end

  it "does not rescan an expanded command catalog for every response" do
    parser = CtxChecker::RuntimeParser.new(platform: :radware_alteon)
    observation = CtxChecker::Observation.new(name: :interfaces, status: :complete,
      records: [ { name: "port1", kind: :physical, source_complete: true } ],
      evidence: [ { command: "/info/link", status: :complete } ])
    expanded = parser.expand({ interfaces: observation }, dimensions: [ :counters ])
    expect(expanded.profile).not_to receive(:commands_for)
    expect(expanded.profile).not_to receive(:parser_for)
    %w[if ether].each do |suffix|
      result = expanded.parse(:counters, "", command: "/stats/port 1/#{suffix}", complete: true)
      expect(result.status).to eq(:failed)
    end
    expect(parser.parse(:counters, "").status).to eq(:failed)
    expect { expanded.parse(:cpu, "", command: "/stats/port 1/if") }.to raise_error(ArgumentError)
  end

  it "keeps duplicate cache evidence effective after diagnostic samples are exhausted" do
    output = ("unexpected row\n" * 200) + <<~CLI
      Memory usage: 1000K total, 900K used, 100K free
      Kernel buffers: 10K Used
      Kernel buffers: 800K Used
      Kernel cached: 50K Used
    CLI
    observation = CtxChecker::RuntimeParser.new(platform: :cisco_nxos).parse(:memory, output, complete: true)
    expect(observation.status).to eq(:partial)
    expect(observation.records.first).to include(basis: :used_including_cache, used_bytes: 921_600, utilization: 90.0)
  end

  it "keeps valid tail records and exact omitted counts without treating truncation as completeness" do
    output = ("unexpected row\n" * 200) + "12:00:00 UTC Sat Oct 17 2026\n"
    observation = CtxChecker::RuntimeParser.new(platform: :cisco_ios).parse(:clock, output, complete: true)
    expect(observation.status).to eq(:partial)
    expect(observation.records.first[:time]).to eq("2026-10-17T12:00:00.000+00:00")
    expect(observation.issues.last).to eq(code: :diagnostics_truncated, count: 72)
  end

  it "bounds each built-in command result while retaining a late command failure" do
    CtxChecker::ParserRegistry::PROFILES.each_key do |platform|
      parser = CtxChecker::RuntimeParser.new(platform: platform)
      parser.profile.commands.each_key do |dimension|
        parser.profile.commands_for(dimension).each do |command|
          observation = parser.parse(dimension, ("--More--\n" * 200) + "Error: failed\n", command: command, complete: true)
          expect(observation.status).to eq(:failed), "#{platform} #{command}: #{observation.issues.inspect}"
          expect(observation.issues.size).to be <= 130
          expect(observation.issues).to include(include(code: :diagnostics_truncated)), "#{platform} #{command}"
        end
      end
    end
  end
end
