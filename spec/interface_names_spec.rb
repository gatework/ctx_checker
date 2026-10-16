# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/parsers/interface_names"

RSpec.describe CtxChecker::Parsers::InterfaceNames do
  it "aligns aliases across interface details, optics and member tables" do
    expect(described_class.normalize("Eth1/1", platform: :cisco_nxos)).to eq("Ethernet1/1")
    expect(described_class.normalize("Po10", platform: :cisco_ios)).to eq("Port-channel10")
    expect(described_class.normalize("XGE1/0/1", platform: :h3c)).to eq("Ten-GigabitEthernet1/0/1")
    expect(described_class.normalize("BAGG10", platform: :h3c)).to eq("Bridge-Aggregation10")
  end

  it "distinguishes physical and logical interfaces including PAN logical dot notation" do
    expect(described_class.kind("ethernet1/1")).to eq(:physical)
    expect(described_class.kind("ethernet1/1.100")).to eq(:subinterface)
    expect(described_class.kind("loopback.1")).to eq(:loopback)
    expect(described_class.kind("tunnel.1")).to eq(:tunnel)
    expect(described_class.kind("Vlan-interface100")).to eq(:svi)
    expect(described_class.kind("ae1")).to eq(:aggregate)
  end

  it "joins Catalyst 25G optical and interface identities without losing subinterfaces" do
    %w[Twe1/0/1 TwentyFiveGigE1/0/1 TwentyFiveGigabitEthernet1/0/1].each do |name|
      expect(described_class.normalize(name, platform: :cisco_ios)).to eq("TwentyFiveGigE1/0/1")
    end
    expect(described_class.kind("TwentyFiveGigE1/0/1")).to eq(:physical)
    expect(described_class.normalize("Twe1/0/1.100", platform: :cisco_ios)).to eq("TwentyFiveGigE1/0/1.100")
    expect(described_class.kind("TwentyFiveGigE1/0/1.100")).to eq(:subinterface)
  end

  it "aligns StoneOS identities without merging bridging and redundancy into LACP" do
    %i[hillstone stoneos].each do |platform|
      expect(described_class.normalize("MGT0", platform: platform)).to eq("mgt0")
      expect(described_class.normalize("Ethernet0/1", platform: platform)).to eq("ethernet0/1")
    end
    { "ha0" => :physical, "mgt0" => :physical, "cellular0/0" => :physical,
      "xethernet0/24" => :physical, "vswitchif1" => :bridge, "bgroup1" => :bridge,
      "redundant1" => :redundant, "aggregate1" => :aggregate }.each do |name, kind|
      expect(described_class.kind(name)).to eq(kind)
    end
  end

  it "normalizes Alteon numeric ports without conflating management and trunk identities" do
    %i[radware_alteon radware alteon].each do |platform|
      expect(described_class.normalize("27", platform: platform)).to eq("port27")
      expect(described_class.normalize("Port 27", platform: platform)).to eq("port27")
      expect(described_class.normalize("MGMT1", platform: platform)).to eq("mgmt1")
    end
    expect(described_class.kind("port27")).to eq(:physical)
    expect(described_class.kind("trunk1")).to eq(:aggregate)
  end
end
