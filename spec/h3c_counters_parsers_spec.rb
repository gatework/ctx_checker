# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker/h3c/parsers/display_counters_inbound_interface"
require "ctx_checker/h3c/parsers/display_counters_outbound_interface"
require "ctx_checker/observation"

RSpec.describe "H3C directional interface counters" do
  {
    inbound: [ CtxChecker::H3c::Parsers::DisplayCountersInboundInterface, :in_errors ],
    outbound: [ CtxChecker::H3c::Parsers::DisplayCountersOutboundInterface, :out_errors ]
  }.each do |direction, (parser_class, metric)|
    context direction.to_s do
      let(:source) { File.read(File.expand_path("fixtures/ctx_checker/h3c/counters_#{direction}.txt", __dir__)) }
      let(:parse) { ->(text, complete: true) { parser_class.parse(text, complete: complete) } }

      it "normalizes physical and aggregate identities while mapping only the direction's error field" do
        result = parse.call(source)
        expect(result.status).to eq(:complete)
        expect(result.records.map { |row| row[:interface] }).to eq(%w[GigabitEthernet1/0/1 Ten-GigabitEthernet1/0/2 Bridge-Aggregation10 Route-Aggregation20])
        expect(result.records.map { |row| row[:metric] }.uniq).to eq([ metric ])
        expect(result.records.map { |row| row[:value] }).to eq(direction == :inbound ? [ 2, 0, 0, 0 ] : [ 0, 7, 0, 0 ])
        expect(result.records.map { |row| row[:discontinuity] }).to all(be_nil)
        expect { CtxChecker::Observation.new(name: :counters, status: result.status, records: result.records, issues: result.issues) }.not_to raise_error
      end

      it "retains overflow and unavailable error counts without interpreting them as zero" do
        [ "Overflow", "--", "-1", "+0", "0.5" ].each do |value|
          text = source.lines.first + "GE1/0/1 123 2 3 #{value}\n"
          result = parse.call(text)
          expect(result.status).to eq(:partial)
          expect(result.records.first).to include(metric: metric, value: nil)
        end
        result = parse.call(source.lines.first + "GE1/0/1 Overflow -- -- 0\n")
        expect(result.status).to eq(:complete)
        expect(result.records.first[:value]).to eq(0)
      end

      it "rejects truncated, duplicate and unfamiliar tables without inventing CRC or discard records" do
        [ source + source.lines.first, source + "GE1/0/9 1 2\n", source + "unrecognized data\n" ].each do |text|
          expect(parse.call(text).status).to eq(:partial)
        end
        result = parse.call(source + "GigabitEthernet1/0/1 1 2 3 4\n")
        expect(result.status).to eq(:partial)
        expect(result.records).not_to include(include(interface: "GigabitEthernet1/0/1"))
        expect(parse.call(source.lines.first).status).to eq(:failed)
        expect(parse.call(source.lines.drop(1).join).status).to eq(:failed)
        expect(parse.call("Interface InOctets InUcastPkts InDiscards InErrors\nGE1/0/1 99 100 1 2\n").status).to eq(:failed)
        expect(parse.call(source).records).not_to include(include(metric: :crc_errors), include(metric: :in_discards), include(metric: :out_discards))
      end

      it "distinguishes packet counts from rates and keeps terminal failures explicit" do
        expect(parse.call(source.gsub("pkts", "pkts/sec")).status).to eq(:failed)
        expect(parse.call(source, complete: false).status).to eq(:partial)
        expect(parse.call(source + "--More--\n").status).to eq(:partial)
        expect(parse.call("Unrecognized command\n").status).to eq(:unsupported)
        expect(parse.call("Error: permission denied\n").status).to eq(:failed)
        expect(parse.call("").status).to eq(:failed)
      end
    end
  end
end
