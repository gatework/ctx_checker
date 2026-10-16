# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/applicability"

RSpec.describe CtxChecker::Applicability do
  def parse(text, platform: :h3c, complete: true, **options)
    described_class.from_configuration(platform: platform, text: text, complete: complete, **options)
  end

  it "proves absence only from complete recognized configurations" do
    { h3c: " sysname LAB\n#\nreturn\n", h3c_wireless: "sysname WLC\nreturn\n",
      cisco_ios: "hostname LAB\nend\n", cisco_nxos: "hostname LAB\nfeature bgp\nfeature ospf\nfeature lacp\nlogging level lacp 5\n" }.each do |platform, text|
      result = parse(text, platform: platform)
      %i[aggregation bgp ospf].each do |name|
        expect(result.state(name)).to eq(:not_configured)
        expect(result.not_applicable?(name)).to be(true)
        expect(parse(text, platform: platform, complete: false).state(name)).to eq(:unknown)
      end
    end
    expect(parse("interface GigabitEthernet1/0/1\n description Uplink\n").state(:bgp)).to eq(:unknown)
    expect(parse("unrecognized text\n").state(:bgp)).to eq(:unknown)
    expect(parse("").state(:bgp)).to eq(:unknown)
    expect(parse("sysname LAB\n").state(:cpu)).to eq(:unknown)
  end

  it "detects Comware aggregation definitions members and routing instances" do
    { aggregation: [ "interface Bridge-Aggregation1\n", "interface Route-Aggregation2\n", "link-aggregation group 3 mode static\n",
      "interface GigabitEthernet1/0/1\n port link-aggregation group 1\n" ],
      bgp: [ "bgp 64512\n", "bgp 64512 instance BLUE\n" ],
      ospf: [ "ospf 1 vpn-instance BLUE\n", "ospfv3 1 vpn-instance BLUE\n", "interface Vlan-interface1\n ospf 1 area 0\n",
        "interface Vlan-interface1\n ospfv3 1 area 0\n" ] }.each do |name, settings|
      settings.each do |setting|
        expect(parse("sysname LAB\n" + setting).state(name)).to eq(:configured), setting
        expect(parse("sysname LAB\n" + setting, complete: false).not_applicable?(name)).to be(false)
      end
    end
  end

  it "detects Cisco aggregation members and IPv4 IPv6 or VRF routing grammar" do
    settings = {
      aggregation: [ "interface Port-channel1\n", "interface port-channel 2\n", "interface Bundle-Ether3\n",
        "interface Ethernet1/1\n channel-group 1 mode active\n" ],
      bgp: [ "router bgp 64512\n", "vrf context BLUE\n router bgp 64512\n",
        "vrf definition BLUE\n address-family ipv4\n  router bgp 64512\n" ],
      ospf: [ "router ospf 1 vrf BLUE\n", "router ospfv3 1\n", "ipv6 router ospf 1\n",
        "interface Ethernet1/1\n ip router ospf 1 area 0.0.0.0\n", "interface GigabitEthernet1/0/1\n ipv6 ospf 1 area 0\n",
        "interface GigabitEthernet1/0/1\n ospfv3 1 ipv4 area 0\n" ]
    }
    %i[cisco_ios cisco_nxos].each do |platform|
      settings.each do |name, variants|
        variants.each { |setting| expect(parse("hostname LAB\n" + setting, platform: platform).state(name)).to eq(:configured), setting }
      end
    end
  end

  it "does not interpret banner contents or arbitrary nested commands as configured features" do
    source = <<~CLI
      hostname LAB
      banner motd ^C
      router bgp 64512
      router ospf 1
      interface Port-channel1
      ^C
      event manager applet note
       router bgp 64512
       router ospf 1
       interface Port-channel1
      interface Ethernet1/1
       description router ospf 1
       unknown-child
        channel-group 1 mode active
      end
    CLI
    result = parse(source, platform: :cisco_nxos)
    expect(%i[aggregation bgp ospf].map { |name| result.state(name) }).to eq([ :not_configured ] * 3)
    nested_identity = parse("unknown-owner\n sysname LAB\n bgp 64512\nreturn\n")
    expect(nested_identity.state(:bgp)).to eq(:unknown)
  end

  it "does not promote paginated errored malformed or open-banner input to absence" do
    [ "--More--", "% Invalid input detected", "Error: permission failure", "Invalid command", "% Unrecognized command",
      "% Unknown command", "% Error reading configuration", "%Error opening system:/running-config (Permission denied)",
      "^---- unrecognized keyword", "Incomplete command", "Permission denied", "\e[0m", "\0", "banner motd",
      "header login information", "banner motd ^C\nunclosed" ].each do |tail|
      result = parse("sysname LAB\n#{tail}\n")
      expect(%i[aggregation bgp ospf].map { |name| result.state(name) }).to eq([ :unknown ] * 3), tail.inspect
    end
    expect(parse("sysname LAB\n".b + "\xff".b).state(:aggregation)).to eq(:unknown)
    expect(parse("sysname LAB\n" + "x" * (16 * 1024 * 1024)).state(:bgp)).to eq(:unknown)
  end

  it "keeps unfamiliar feature grammar and unsupported vendors unresolved" do
    expect(parse("sysname LAB\nfuture ospf 1\n").state(:ospf)).to eq(:unknown)
    expect(parse("sysname LAB\ninterface Bridge-Aggregation\n").state(:aggregation)).to eq(:unknown)
    expect(parse("hostname LAB\ninterface Ethernet1/1\n future ospf 1\n", platform: :cisco_nxos).state(:ospf)).to eq(:unknown)
    expect(parse("hostname LAB\nvrf context BLUE\n future ospf 1\n", platform: :cisco_nxos).state(:ospf)).to eq(:unknown)
    %i[hillstone palo_alto radware juniper].each do |platform|
      result = parse("hostname LAB\n", platform: platform)
      expect(%i[aggregation bgp ospf].map { |name| result.state(name) }).to eq([ :unknown ] * 3)
    end
  end

  it "keeps Comware banner contents opaque when they resemble a truncated header command" do
    result = parse("sysname LAB\nheader login information ^C\nheader login information\nbgp 64512\n^C\nreturn\n")
    expect(result.state(:bgp)).to eq(:not_configured)
  end

  it "stores immutable provenance without retaining configuration text or exposing it through inspect" do
    text = +"sysname LAB\nlocal-user user\n password cipher PRIVATE-CREDENTIAL\n"
    reference = +"private/backup/configuration.txt"
    result = parse(text, platform: :h3c_wireless, reference: reference)
    expect(result.platform).to eq("h3c")
    expect(result.evidence).to eq([ { sha256: Digest::SHA256.hexdigest(text), bytes: text.bytesize, reference: reference } ])
    expect(result.inspect).not_to include("PRIVATE-CREDENTIAL", "private/backup")
    text.replace("changed")
    reference.replace("changed")
    expect(result.evidence.first[:reference]).to eq("private/backup/configuration.txt")
    expect { result.evidence.first[:bytes] = 0 }.to raise_error(FrozenError)
    expect { result.platform.replace("palo_alto") }.to raise_error(FrozenError)
    expect(result).to be_frozen
  end

  it "rejects invalid public options instead of silently coercing completeness" do
    expect { parse("sysname LAB", complete: "true") }.to raise_error(ArgumentError)
    expect { parse(nil) }.to raise_error(ArgumentError)
    expect { parse("sysname LAB", platform: "h3c\n") }.to raise_error(ArgumentError)
    expect { parse("sysname LAB", reference: "unsafe\nreference") }.to raise_error(ArgumentError)
  end
end
