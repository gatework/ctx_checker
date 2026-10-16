# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/runtime_parser"

RSpec.describe "PAN-OS observed runtime format variants" do
  def parse(dimension, text, complete: true)
    CtxChecker::RuntimeParser.new(platform: :palo_alto).parse(dimension, text, complete: complete)
  end

  it "keeps hardware CPU counters when interfaces recur in the logical inventory" do
    body = <<~TEXT
      Hardware interface counters:
      ----------------------------------------------------------------
      Interface: ethernet1/1
      Physical port counters read from MAC:
      rx-unicast 200
      Hardware interface counters read from CPU:
      receive errors 7
      receive discarded 3
      packets dropped 1
      Logical interface counters:
      ----------------------------------------------------------------
      Interface: ethernet1/1
      Logical interface counters read from CPU:
      receive errors 19
      packets dropped 31
      tcp cps 8
      Interface: tunnel.1
      Logical interface counters read from CPU:
      receive errors 11
      packets dropped 13
      tcp cps 2
      udp cps 0
      sctp cps 0
      other cps 0
    TEXT
    result = parse(:counters, body)
    expect(result.status).to eq(:partial)
    expect(result.records).to include(include(interface: "ethernet1/1", metric: :in_errors, value: 7, scope: :cpu),
      include(interface: "ethernet1/1", metric: :in_discards, value: 3, scope: :cpu),
      include(interface: "tunnel.1", metric: :in_errors, value: 11, scope: :logical))
    expect(result.issues.map { |row| row[:code] }.uniq).to eq([ :missing_counter_metrics ])
    expect(result.records).to include(include(interface: "tunnel.1", metric: :in_discards, value: nil))
    expect(result.records.size).to eq(10)
  end

  it "still discards duplicate metrics within the chosen layer" do
    body = "Interface: ethernet1/1\nHardware interface counters read from CPU:\nreceive errors 3\n"
    result = parse(:counters, body + body)
    expect(result.status).to eq(:partial)
    expect(result.records).not_to include(include(interface: "ethernet1/1", metric: :in_errors))
    expect(result.issues).to include(include(code: :duplicate_identity))
  end

  it "recognizes available NTP backups without claiming they are synchronized" do
    body = <<~TEXT
      NTP state:
          NTP synched to time.example.test
          NTP server: time.example.test
              status: synched
              reachable: yes
              authentication-type: none
          NTP server: backup.example.test
              status: available
              reachable: yes
              authentication-type: none
    TEXT
    result = parse(:ntp, body)
    expect(result).to be_complete
    expect(result.records.first).to include(component: "system", synchronized: true)
    expect(result.records.last).to include(component: "peer/backup.example.test", synchronized: nil)
    expect(parse(:ntp, body.sub("status: available", "status: unrecognized")).status).to eq(:partial)
  end

  it "accepts mixed-case metric names and retains negative counters as unresolved" do
    body = <<~TEXT
      Global counters:
      name value rate severity category aspect description
      pkt_pvst_non_L2 7 0 info packet pktproc Synthetic L2 context
      flow_rcv_err 2 0 drop flow parse Synthetic packet error
      Total counters shown: 2
    TEXT
    result = parse(:device_counters, body)
    expect(result).to be_complete
    expect(result.records).to include(include(metric: "pkt_pvst_non_L2", category: :informational, value: 7))
    expect(parse(:device_counters, body.sub("flow_rcv_err 2", "flow_rcv_err -2")).status).to eq(:partial)
  end

  it "separates local alarm states from configured thresholds and replicated peer alarms" do
    body = <<~TEXT
      cfg.diskquota.alarm: 557
      peer.env.s1.mp.power-supply.0: { 'alarm': True, 'inserted': True, }
      env.s1.mp.power-supply.0: { 'alarm': False, 'inserted': True, }
      ha.app.local.alarm: False
      chassis.s0.leds: { 'alarm': Off, 'power': Green, }
      hw.s1.mp.leds: { 'alarm': Red, 'power': Green, }
    TEXT
    result = parse(:alarms, body)
    expect(result).to be_complete
    expect(result.records.size).to eq(4)
    expect(result.records).to include(include(component: "env.s1.mp.power-supply.0", active: false),
      include(component: "hw.s1.mp.leds", active: true))
    expect(result.records.map { |row| row[:component] }).not_to include(start_with("peer."))
    expect(parse(:alarms, body + "sw.logrcvr.runtime.alarm: <opaque-state>\n").status).to eq(:partial)
    expect(parse(:alarms, "cfg.diskquota.alarm: 557\n").status).to eq(:failed)
  end
end
