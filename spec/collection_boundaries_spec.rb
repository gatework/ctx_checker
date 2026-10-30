# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Collection input and connector boundaries" do
  let(:target) { { host: +"192.0.2.10", platform: "cisco_ios" } }
  let(:time) { Time.utc(2026, 10, 18) }
  let(:body) { "GigabitEthernet1/0/1 is up, line protocol is up\n" }
  let(:session) { double(:session, connected?: true) }

  it "fixes the selected dimensions before invoking the caller clock" do
    dimensions = [ :interfaces ]
    clock = -> { dimensions.replace([ :bgp ]); time }
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).once.and_return(command_receipt(body))

    snapshot = CtxChecker::Collector.new(clock: clock).collect_session(target: target, session: session, dimensions: dimensions)

    expect(snapshot.observation(:interfaces).records.first[:name]).to eq("GigabitEthernet1/0/1")
    expect(snapshot.observation(:bgp).status).to eq(:not_requested)
    expect(dimensions).to eq([ :bgp ])
  end

  it "fixes the validated target before invoking the caller clock" do
    clock = -> { target[:host].replace("192.0.2.99"); time }
    expect(session).to receive(:send_commands).and_return(command_receipt(body))

    snapshot = CtxChecker::Collector.new(clock: clock).collect_session(target: target, session: session, dimensions: [ :interfaces ])

    expect(snapshot.target.host).to eq("192.0.2.10")
    expect(target[:host]).to eq("192.0.2.99")
    expect(target[:host]).not_to be_frozen
  end

  it "rejects an open protocol that never provides a session" do
    connector = double(:connector, open: nil)
    snapshot = CtxChecker::Collector.new(clock: -> { time }).collect(target: target, connector: connector, dimensions: [ :interfaces ])
    expect(snapshot.issues).to include(include(code: :session_not_opened))
    expect(CtxChecker::Evaluator.new.call(snapshot).status).to eq(:unknown)
  end

  it "never executes a second collection when open yields twice" do
    connector = Object.new
    borrowed = session
    connector.define_singleton_method(:open) { |&block| 2.times { block.call(borrowed) } }
    expect(session).to receive(:send_commands).with([ "show interfaces" ]).once.and_return(command_receipt(body))

    snapshot = CtxChecker::Collector.new(clock: -> { time }).collect(target: target, connector: connector, dimensions: [ :interfaces ])
    expect(snapshot.issues).to include(include(code: :session_reentered))
    expect(CtxChecker::Evaluator.new.call(snapshot).status).to eq(:unknown)
  end
end

RSpec.describe CtxChecker::ObservationMerger do
  it "rejects unrequested observations as command results instead of certifying completion" do
    fragment = CtxChecker::Observation.new(name: :interfaces, status: :not_requested,
      evidence: [ { command: "show interfaces" } ])

    expect do
      described_class.call(:interfaces, [ fragment ], commands: [ "show interfaces" ])
    end.to raise_error(ArgumentError)
  end
end
