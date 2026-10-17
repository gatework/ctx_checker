# frozen_string_literal: true

require_relative "spec_helper"
require "bigdecimal"

RSpec.describe "Time policy snapshots" do
  it "rejects unsupported numeric values during policy construction" do
    mutable_numeric = Class.new(Numeric) do
      def real? = true
      def finite? = true
      def >=(_other) = true
    end.new
    %i[max_ntp_offset_ms max_clock_skew_seconds].each do |key|
      [ BigDecimal("100"), mutable_numeric ].each do |value|
        expect { CtxChecker::Policy.new(**{ key => value }) }.to raise_error(ArgumentError)
      end
    end
  end

  it "preserves exact rational thresholds through NTP evaluation" do
    policy = CtxChecker::Policy.new(max_ntp_offset_ms: Rational(1, 3))
    observation = CtxChecker::Observation.new(name: :ntp, status: :complete,
      records: [ { component: "system", synchronized: true, stratum: 2, offset_ms: 0 } ])
    snapshot = CtxChecker::Snapshot.new(target: { host: "192.0.2.1", platform: "h3c" }, observed_at: Time.now, observations: { ntp: observation })
    finding = CtxChecker::Evaluator.new(policy: policy).call(snapshot).findings.find { |row| row.reason == :ntp_offset }
    expect(finding.expected).to eq(maximum_absolute_ms: Rational(1, 3))
    expect(finding.status).to eq(:pass)
  end
end
