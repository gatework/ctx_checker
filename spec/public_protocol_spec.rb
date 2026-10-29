# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CtxChecker::Snapshot do
  it "distinguishes known unrequested observations from unknown names" do
    snapshot = described_class.new(target: { host: "192.0.2.1", platform: "cisco_ios" }, observed_at: Time.utc(2026), observations: {})
    expect(snapshot.observation(:interfaces).status).to eq(:not_requested)
    expect { snapshot.observation(:invented) }.to raise_error(ArgumentError, "Unknown observation dimension")
  end
end
