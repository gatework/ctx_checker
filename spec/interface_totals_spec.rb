# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CtxChecker::PaloAlto::Parsers::ShowInterfaceAll do
  it "preserves conflicting count evidence instead of accepting the last declaration" do
    text = "total configured hardware interfaces: 2\nethernet1/1 1 auto/auto/up 00:11:22:33:44:55\ntotal configured hardware interfaces: 1\n"
    result = described_class.new.parse(text, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.records.size).to eq(1)
    expect(result.issues).to include(include(code: :conflicting_count, section: :hardware))
  end
end
