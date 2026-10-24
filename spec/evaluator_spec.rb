# frozen_string_literal: true

require_relative "spec_helper"
require "json"
require "ctx_checker/evaluator"
require "ctx_checker/runtime_parser"

RSpec.describe CtxChecker::Evaluator do
  let(:target) { { host: "192.0.2.1", platform: "cisco_nxos" } }
  let(:up) { { name: "Ethernet1/1", kind: :physical, admin_status: :up, oper_status: :up, protocol_status: :up } }
  let(:bgp) { { vrf: "default", afi_safi: "ipv4_unicast", peer: "192.0.2.2", state: :established, received_prefixes: 0 } }
  let(:ospf) { { vrf: "default", process_id: "1", area: "0.0.0.0", interface: "Ethernet1/1", router_id: "192.0.2.2", state: :full } }
  let(:optic) { { interface: "Ethernet1/1", lane: 0, metric: :rx_power, value: -3.0, unit: :dbm, low_alarm: -18.0, low_warning: -14.0, high_warning: 0.5, high_alarm: 3.5, present: true, dom_supported: true } }

  def observation(name, records = [], status: :complete, **options)
    CtxChecker::Observation.new(name: name, records: records, status: status, **options)
  end

  def snapshot(*rows, time: Time.utc(2026, 10, 15, 2), issues: [], host: target)
    CtxChecker::Snapshot.new(target: host, observed_at: time, observations: rows.to_h { |row| [ row.name, row ] }, issues: issues)
  end

  def evaluate(*rows, policy: CtxChecker::Policy.new, previous: nil, **options)
    described_class.new(policy: policy).call(snapshot(*rows, **options), previous: previous)
  end

  def findings(report, dimension) = report.findings.select { |row| row.dimension == dimension }

  it "never marks an empty or unavailable dataset healthy" do
    expect(evaluate.status).to eq(:unknown)
    %i[complete partial failed unsupported].each do |status|
      report = evaluate(observation(:interfaces, status: status))
      expect(report).not_to be_healthy
      expect(findings(report, :interfaces).first.status).to eq(:unknown)
    end
  end

  it "accepts complete physical and logical states and ignores intentionally shutdown ports" do
    report = evaluate(observation(:interfaces, [ up, up.merge(name: "Vlan10", kind: :svi), up.merge(name: "Ethernet1/2", admin_status: :down, oper_status: :down) ]))
    expect(report).to be_healthy
    expect(findings(report, :interfaces).map(&:status)).to eq(%i[pass pass not_applicable])
  end

  it "accepts observed physical and aggregate links without requiring an IOS line-protocol field" do
    text = File.read(File.expand_path("fixtures/ctx_checker/cisco_nxos/interface.txt", __dir__))
    observation = CtxChecker::RuntimeParser.new(platform: "cisco_nxos").parse(:interfaces, text, complete: true)
    expect(observation.records.find { |row| row[:name] == "Ethernet1/1" }[:protocol_status]).to eq(:unknown)
    by_name = findings(evaluate(observation), :interfaces).to_h { |row| [ row.entity, row ] }
    expect(by_name.fetch("Ethernet1/1").status).to eq(:pass)
    expect(by_name.fetch("Port-channel1").status).to eq(:pass)
    expect(by_name.fetch("Loopback0").status).to eq(:unknown)
    logical = up.merge(name: "Tunnel1", kind: :tunnel, protocol_status: :unknown)
    expect(findings(evaluate(self.observation(:interfaces, [ logical ])), :interfaces).first.status).to eq(:unknown)
  end

  it "fails required down or missing interfaces while ordinary down is a warning" do
    policy = CtxChecker::Policy.new(required_interfaces: %w[Ethernet1/1 Ethernet1/3])
    report = evaluate(observation(:interfaces, [ up.merge(oper_status: :down, admin_status: :down), up.merge(name: "Ethernet1/2", oper_status: :down) ]), policy: policy)
    expect(findings(report, :interfaces).map(&:severity)).to eq(%i[critical warning critical])
    expect(report.status).to eq(:fail)
    missing = evaluate(policy: policy)
    expect(findings(missing, :interfaces).map(&:status)).to all(eq(:unknown))
  end

  it "accepts explicit layer two protocol inapplicability while retaining real link faults" do
    bridge = up.merge(name: "vswitchif1", kind: :bridge, protocol_status: :down, protocol_applicable: false)
    expect(findings(evaluate(observation(:interfaces, [ bridge ])), :interfaces).first.status).to eq(:pass)
    [ { oper_status: :down }, { protocol_applicable: true }, { protocol_applicable: nil } ].each do |variant|
      expect(findings(evaluate(observation(:interfaces, [ bridge.merge(variant) ])), :interfaces).first.status).to eq(:fail)
    end
    expect(findings(evaluate(observation(:interfaces, [ bridge ], status: :partial)), :interfaces).first.status).to eq(:unknown)
    expect(findings(evaluate(observation(:interfaces, [ bridge.merge(oper_status: :unknown) ])), :interfaces).first.status).to eq(:unknown)
    expect { observation(:interfaces, [ bridge.merge(protocol_applicable: "false") ]) }.to raise_error(ArgumentError)
  end

  it "retains proven faults while refusing to certify partial healthy rows" do
    report = evaluate(observation(:interfaces, [ up, up.merge(name: "Ethernet1/2", oper_status: :down) ], status: :partial))
    expect(findings(report, :interfaces).map(&:status)).to eq(%i[unknown fail])
    expect(report.status).to eq(:fail)
    expect(report).not_to be_complete
    expect(report.coverage).to eq(50.0)
  end

  it "keeps CRC and error totals distinct and describes positive single samples as historical" do
    rows = [ { interface: "Ethernet1/1", metric: :in_errors, value: 12, unit: :packets, scope: :interface },
      { interface: "Ethernet1/1", metric: :crc_errors, value: 7, unit: :packets, scope: :interface } ]
    report = evaluate(observation(:counters, rows))
    expect(findings(report, :counters).map(&:actual)).to eq([ 12, 7 ])
    expect(findings(report, :counters).map(&:reason)).to eq([ :cumulative_errors, :cumulative_errors ])
    expect(findings(report, :counters).map(&:status)).to all(eq(:unknown))
    expect(findings(report, :counters).map(&:severity)).to all(eq(:warning))
    expect(evaluate(observation(:counters, [ rows.first.merge(value: 0) ]))).to be_healthy
  end

  it "calculates deltas only with matching counter epochs and earlier samples" do
    row = { interface: "Ethernet1/1", metric: :crc_errors, value: 10, unit: :packets, scope: :interface, discontinuity: "boot-1/clear-1" }
    earlier = snapshot(observation(:counters, [ row ]), time: Time.utc(2026, 10, 15, 1, 59))
    report = evaluate(observation(:counters, [ row.merge(value: 13) ]), previous: earlier, policy: CtxChecker::Policy.new(counter_limits: { crc_errors: 2 }))
    expect(findings(report, :counters).first.to_h).to include(status: :fail, reason: :counter_delta, actual: { delta: 3, seconds: 60.0 })
    [ row.merge(discontinuity: nil), row.merge(discontinuity: "boot-2"), row.merge(value: 1) ].each do |current|
      expect(findings(evaluate(observation(:counters, [ current ]), previous: earlier), :counters).first.status).to eq(:unknown)
    end
    expect { evaluate(observation(:counters, [ row ]), previous: snapshot(observation(:counters, [ row ]))) }.to raise_error(ArgumentError)
    expect { evaluate(previous: snapshot(host: target.merge(host: "192.0.2.9")), time: Time.utc(2026, 10, 15, 3)) }.to raise_error(ArgumentError)
  end

  it "uses command sample times and retains proven deltas from partial evidence" do
    row = { interface: "Ethernet1/1", metric: :crc_errors, value: 10, unit: :packets, scope: :interface, discontinuity: "boot-1/clear-1" }
    prior = observation(:counters, [ row ], status: :partial, evidence: [ { observed_at: "2026-10-15T01:59:45Z" } ])
    earlier = snapshot(prior, time: Time.utc(2026, 10, 15, 1, 59))
    current = observation(:counters, [ row.merge(value: 13) ], status: :partial, evidence: [ { observed_at: "2026-10-15T01:59:50Z" } ])
    results = findings(evaluate(current, previous: earlier), :counters)
    expect(results.first.to_h).to include(status: :fail, actual: { delta: 3, seconds: 5.0 })
    expect(results.last.reason).to eq(:incomplete_evidence)
    unchanged = observation(:counters, [ row ], evidence: [ { observed_at: "2026-10-15T01:59:50Z" } ])
    expect(findings(evaluate(unchanged, previous: earlier), :counters).first.reason).to eq(:counter_evidence_incomplete)
    old = observation(:counters, [ row.merge(value: 13) ], evidence: [ { observed_at: "2026-10-15T01:59:40Z" } ])
    expect(findings(evaluate(old, previous: earlier), :counters).first.reason).to eq(:counter_sample_time_invalid)
  end

  it "preserves aggregation standby and detects degraded members and explicit capacity" do
    member = { group: "Port-channel1", member: "Ethernet1/1", member_status: :active, oper_status: :up }
    rows = [ member, member.merge(member: "Ethernet1/2", member_status: :standby), member.merge(member: "Ethernet1/3", member_status: :down, oper_status: :down) ]
    policy = CtxChecker::Policy.new(required_members: { "Port-channel1" => %w[Ethernet1/1 Ethernet1/4] }, minimum_active_members: { "Port-channel1" => 2 })
    report = evaluate(observation(:aggregation, rows), policy: policy)
    expect(findings(report, :aggregation).map(&:status)).to eq(%i[pass pass fail fail fail])
    expect(findings(report, :aggregation).last.reason).to eq(:aggregation_capacity)
    partial = evaluate(observation(:aggregation, [ member ], status: :partial), policy: policy)
    expect(findings(partial, :aggregation).map(&:status)).to all(eq(:unknown))
  end

  it "does not interpret an unavailable member list as a proven empty aggregate" do
    policy = CtxChecker::Policy.new(required_members: { "Port-channel1" => [ "Ethernet1/1" ] }, minimum_active_members: { "Port-channel1" => 1 })
    placeholder = { group: "Port-channel1", member: nil, member_status: :unknown, oper_status: :up }
    results = findings(evaluate(observation(:aggregation, [ placeholder ]), policy: policy), :aggregation)
    expect(results.map(&:status)).to all(eq(:unknown))
    absent = findings(evaluate(observation(:aggregation), policy: policy), :aggregation)
    expect(absent.map(&:status)).to all(eq(:fail))
  end

  it "uses module thresholds for every lane and honors inclusive healthy boundaries" do
    rows = [ optic, optic.merge(lane: 1, value: -14.0), optic.merge(lane: 2, value: -15.0), optic.merge(lane: 3, value: -19.0) ]
    result = findings(evaluate(observation(:optics, rows)), :optics)
    expect(result.map(&:status)).to eq(%i[pass pass fail fail])
    expect(result.map(&:severity)).to eq(%i[info info warning critical])
  end

  it "refuses missing DOM, unknown values and invalid thresholds while preserving explicit alarms" do
    variants = [ { dom_supported: false }, { present: false }, { value: nil }, { low_warning: 9 } ]
    variants.each do |variant|
      expect(findings(evaluate(observation(:optics, [ optic.merge(variant) ])), :optics).first.status).to eq(:unknown)
    end
    report = evaluate(observation(:optics, [ optic.merge(value: nil, alarm: :low_alarm) ]))
    expect(findings(report, :optics).first.status).to eq(:fail)
    partial_bounds = optic.merge(low_warning: nil, high_warning: nil, high_alarm: nil)
    expect(findings(evaluate(observation(:optics, [ partial_bounds.merge(value: -19) ])), :optics).first.to_h).to include(status: :fail, severity: :critical)
    expect(findings(evaluate(observation(:optics, [ partial_bounds ])), :optics).first.status).to eq(:unknown)
    shutdown = evaluate(observation(:interfaces, [ up.merge(admin_status: :down, oper_status: :down) ]), observation(:optics, [ optic.merge(value: -30) ]))
    expect(findings(shutdown, :optics).first.status).to eq(:not_applicable)
  end

  it "uses a complete alarm or warning threshold pair without inventing the missing thresholds" do
    alarm_only = optic.merge(low_warning: nil, high_warning: nil)
    expect(findings(evaluate(observation(:optics, [ alarm_only ])), :optics).first.status).to eq(:pass)
    expect(findings(evaluate(observation(:optics, [ alarm_only.merge(value: -19) ])), :optics).first.to_h).to include(status: :fail, severity: :critical)
    warning_only = optic.merge(low_alarm: nil, high_alarm: nil)
    expect(findings(evaluate(observation(:optics, [ warning_only ])), :optics).first.status).to eq(:pass)
    expect(findings(evaluate(observation(:optics, [ warning_only.merge(value: -15) ])), :optics).first.to_h).to include(status: :fail, severity: :warning)
  end

  it "retains optical faults when explicit alarm state disagrees with measured thresholds" do
    [ optic.merge(alarm: :low_alarm), optic.merge(alarm: :normal, value: -19), optic.merge(alarm: :low_warning, value: -19) ].each do |row|
      report = evaluate(observation(:optics, [ row ]))
      expect(report.status).to eq(:fail)
      expect(report).not_to be_complete
      expect(findings(report, :optics).last.reason).to eq(:optical_alarm_threshold_disagreement)
      expect(findings(report, :optics).any? { |finding| finding.status == :fail && finding.severity == :critical }).to be(true)
    end
  end

  it "applies exact lane policies without masking explicit module alarms" do
    no_thresholds = optic.merge(low_alarm: nil, low_warning: nil, high_warning: nil, high_alarm: nil)
    policy = CtxChecker::Policy.new(optical_thresholds: [ { interface: "Ethernet1/1", lane: 0, metric: :rx_power, low_alarm: -10, high_alarm: 2 } ])
    report = evaluate(observation(:optics, [ no_thresholds, no_thresholds.merge(lane: 1) ]), policy: policy)
    expect(findings(report, :optics).map(&:status)).to eq(%i[pass unknown])
    report = evaluate(observation(:optics, [ no_thresholds.merge(alarm: :low_alarm) ]), policy: policy)
    expect(findings(report, :optics).first.to_h).to include(status: :fail, reason: :optical_alarm)
    stricter = CtxChecker::Policy.new(optical_thresholds: [ { interface: "Ethernet1/1", lane: 0, metric: :rx_power, low_warning: -2, high_warning: 2 } ])
    report = evaluate(observation(:optics, [ optic.merge(alarm: :normal) ]), policy: stricter)
    expect(findings(report, :optics).map(&:reason)).to eq([ :optical_threshold ])
    expect(report.status).to eq(:fail)
  end

  it "accepts established BGP with zero prefixes and separates address families and VRFs" do
    expect(evaluate(observation(:bgp, [ bgp ]))).to be_healthy
    report = evaluate(observation(:bgp, [ bgp, bgp.merge(vrf: "blue", state: :active), bgp.merge(afi_safi: "l2vpn_evpn", state: :idle) ]))
    expect(findings(report, :bgp).map(&:status)).to eq(%i[pass fail fail])
    unknown = evaluate(observation(:bgp, [ bgp.merge(vrf: nil) ]))
    expect(findings(unknown, :bgp).first.reason).to eq(:protocol_scope_unavailable)
  end

  it "requires topology before accepting OSPF two-way and never calls a known bad state healthy" do
    two_way = ospf.merge(state: :two_way)
    rows = [ two_way, two_way.merge(router_id: "192.0.2.3", network_type: :broadcast, local_role: :drother, neighbor_role: :drother), ospf.merge(router_id: "192.0.2.4", state: :init) ]
    expect(findings(evaluate(observation(:ospf, rows)), :ospf).map(&:status)).to eq(%i[unknown pass fail])
    expect(evaluate(observation(:ospf, [ ospf ]))).to be_healthy
    expect(findings(evaluate(observation(:ospf, [ ospf.merge(interface: nil) ])), :ospf).first.status).to eq(:unknown)
    [ { network_type: :point_to_point }, { network_type: :point_to_multipoint }, { network_type: :virtual_link },
      { network_type: :broadcast, local_role: :dr }, { network_type: :nbma, neighbor_role: :bdr } ].each do |topology|
      report = evaluate(observation(:ospf, [ two_way.merge(topology) ]))
      expect(findings(report, :ospf).first.to_h).to include(status: :fail, reason: :ospf_expected_adjacency_missing)
    end
  end

  it "detects missing expected peers only when their scope was observed completely" do
    expected = bgp.slice(:vrf, :afi_safi, :peer).merge(peer: "192.0.2.9")
    policy = CtxChecker::Policy.new(expected_bgp: [ expected ])
    expect(findings(evaluate(observation(:bgp, [ bgp ]), policy: policy), :bgp).last.status).to eq(:fail)
    expect(findings(evaluate(observation(:bgp, [ bgp ], status: :partial), policy: policy), :bgp).last.status).to eq(:unknown)
    expect(findings(evaluate(observation(:bgp, [ bgp.merge(vrf: "blue") ]), policy: policy), :bgp).last.status).to eq(:unknown)
    expect(findings(evaluate(observation(:bgp), policy: policy), :bgp).last.status).to eq(:unknown)
  end

  it "keeps connection lifecycle issues visible and serializes compact reports" do
    report = evaluate(observation(:interfaces, [ up ]), issues: [ { code: :session_close_failed } ])
    expect(report.status).to eq(:unknown)
    expect(report).not_to be_complete
    expect(report.to_text).to include("session_close_failed")
    expect(report.summary[:findings].first).not_to have_key(:actual)
    expect(JSON.parse(JSON.generate(report.to_h))).to include("status" => "unknown")
    expect(evaluate(observation(:interfaces, [ up.merge(oper_status: :down) ]), issues: [ { code: :session_close_failed } ]).status).to eq(:fail)
  end
end
