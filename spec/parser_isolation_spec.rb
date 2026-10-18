# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"

RSpec.describe CtxChecker::RuntimeParser, "failure isolation" do
  let(:parser) { CtxChecker::RuntimeParser.new(platform: :cisco_nxos) }
  let(:command) { "show system resources" }
  let(:cpu_record) { { component: "processor", scope: "system", utilization: 10 } }
  let(:memory_record) { { component: "system", scope: "system", utilization: 20, basis: :used_total } }
  let(:cpu_result) { CtxParser::Result.new(status: :complete, records: [ cpu_record ]) }
  let(:memory_result) { CtxParser::Result.new(status: :complete, records: [ memory_record ]) }
  let(:implementation) { parser.profile.parser_for(:cpu) }

  def parse_resources
    parser.parse_many(%i[cpu memory], "synthetic private output", complete: true)
  end

  it "contains parser exceptions at one command and omits exception details from evidence" do
    expect(implementation).to receive(:parse).once.and_raise(ArgumentError, "private token from unsupported syntax")
    results = parse_resources
    expect(results.keys).to eq(%i[cpu memory])
    results.each_value do |observation|
      expect(observation.status).to eq(:failed)
      expect(observation.records).to be_empty
      expect(observation.issues).to include(include(code: :parser_error, stage: :parse, command: command, error_type: "ArgumentError"))
      expect(observation.evidence).to include(include(command: command, status: :failed, bytes: 24))
      expect(observation.to_h.to_s).not_to include("private", "token", "unsupported syntax", "backtrace")
    end
  end

  it "keeps a valid view when another projection is absent without parsing twice" do
    expect(implementation).to receive(:parse).once.and_return(CtxParser::Results.new(by_dimension: { cpu: cpu_result }))
    results = parse_resources
    expect(results[:cpu]).to be_complete
    expect(results[:cpu].records.first).to include(utilization: 10, source_complete: true)
    expect(results[:memory].status).to eq(:failed)
    expect(results[:memory].issues).to include(include(code: :missing_parser_view, stage: :project, command: command, error_type: "KeyError"))
  end

  it "isolates invalid observation schemas from sibling views" do
    bad_memory = CtxParser::Result.new(status: :complete, records: [ memory_record.merge(utilization: 101) ])
    expect(implementation).to receive(:parse).once.and_return(CtxParser::Results.new(by_dimension: { cpu: cpu_result, memory: bad_memory }))
    results = parse_resources
    expect(results[:cpu]).to be_complete
    expect(results[:memory].status).to eq(:failed)
    expect(results[:memory].issues).to include(include(code: :invalid_observation, stage: :validate, error_type: "ArgumentError"))
  end

  it "contains one projection's runtime exception without discarding an earlier valid view" do
    results_class = Class.new(CtxParser::Results) do
      def fetch(name)
        raise RuntimeError, "private projection details" if name == :memory

        super
      end
    end
    result = results_class.new(by_dimension: { cpu: cpu_result, memory: memory_result })
    expect(implementation).to receive(:parse).once.and_return(result)
    results = parse_resources
    expect(results[:cpu]).to be_complete
    expect(results[:memory].status).to eq(:failed)
    expect(results[:memory].issues).to include(include(code: :parser_projection_failed, stage: :project, error_type: "RuntimeError"))
    expect(results[:memory].to_h.to_s).not_to include("private projection details")
  end

  it "marks a non-result parser return as an invalid observation" do
    expect(implementation).to receive(:parse).once.and_return(nil)
    expect(parse_resources.values).to all(have_attributes(status: :failed))
  end

  it "derives source completeness instead of trusting parser-supplied metadata" do
    partial = CtxParser::Result.new(status: :partial, records: [ cpu_record.merge(source_complete: true) ])
    full = CtxParser::Result.new(status: :complete, records: [ memory_record.merge(source_complete: false) ])
    expect(implementation).to receive(:parse).once.and_return(CtxParser::Results.new(by_dimension: { cpu: partial, memory: full }))
    results = parse_resources
    expect(results[:cpu].records.first[:source_complete]).to be(false)
    expect(results[:cpu].evidence.first[:status]).to eq(:partial)
    expect(results[:cpu].issues).to include(include(code: :incomplete_command_output))
    expect(results[:memory].records.first[:source_complete]).to be(true)
    expect(results[:memory].evidence.first[:status]).to eq(:complete)
  end

  it "keeps valid offline sources when another model command parser raises" do
    parser = CtxChecker::RuntimeParser.new(platform: :h3c)
    inbound = "display counters inbound interface"
    outbound = "display counters outbound interface"
    inbound_parser = parser.profile.parser_for(:counters, command: inbound)
    outbound_parser = parser.profile.parser_for(:counters, command: outbound)
    expect(inbound_parser).to receive(:parse).once.and_raise(NoMethodError, "private data")
    expect(outbound_parser).to receive(:parse).once.and_return(CtxParser::Result.new(status: :complete,
      records: [ { interface: "GigabitEthernet1/0/1", metric: :out_errors, value: 0 } ]))
    observation = parser.parse_outputs(:counters, { inbound => "first", outbound => "second" }, complete: true)
    expect(observation.status).to eq(:partial)
    expect(observation.records).to include(include(metric: :out_errors, value: 0, source_complete: true))
    expect(observation.issues).to include(include(code: :parser_error, command: inbound))
    expect(observation.evidence).to include(include(command: inbound, status: :failed), include(command: outbound, status: :complete))
    expect(observation.to_h.to_s).not_to include("private data")
  end

  it "binds counter source commands to the catalog instead of parser-supplied metadata" do
    command = "show interface"
    counter = { interface: "Ethernet1/1", metric: :in_errors, value: 3, source_command: "invented command" }
    implementation = parser.profile.parser_for(:counters, command: command)
    allow(implementation).to receive(:parse).and_return(CtxParser::Result.new(status: :complete, records: [ counter ]))

    observation = parser.parse(:counters, "synthetic", command: command, complete: true)

    expect(observation.records.first).to include(source_command: command, source_complete: true)
    expect(observation.evidence.first[:command]).to eq(command)
    expect(observation.to_h.to_s).not_to include("invented command")
  end

  it "keeps a command's original completeness separate from missing sibling sources" do
    parser = CtxChecker::RuntimeParser.new(platform: :h3c)
    command = "display counters outbound interface"
    implementation = parser.profile.parser_for(:counters, command: command)
    allow(implementation).to receive(:parse).and_return(CtxParser::Result.new(status: :complete,
      records: [ { interface: "GigabitEthernet1/0/1", metric: :out_errors, value: 0 } ]))
    observation = parser.parse(:counters, "synthetic", command: command, complete: true)
    expect(observation.status).to eq(:partial)
    expect(observation.evidence.first[:status]).to eq(:complete)
    expect(observation.records.first[:source_complete]).to be(true)
  end

  it "rejects caller mistakes before invoking the command parser" do
    expect(implementation).not_to receive(:parse)
    expect { parser.parse_many(%i[cpu cpu], "body") }.to raise_error(ArgumentError)
    expect { parser.parse(:cpu, nil) }.to raise_error(ArgumentError)
    expect { parser.parse(:cpu, "body", complete: :yes) }.to raise_error(ArgumentError)
    expect { parser.parse(:cpu, "body", command: "undeclared") }.to raise_error(ArgumentError)
  end

  it "rejects broken command catalogs before collection can start" do
    profile = Class.new(CtxParser::Profile)
    profile.const_set(:COMMANDS, { cpu: command })
    profile.const_set(:PARSERS, {})
    allow(CtxChecker::ParserRegistry).to receive(:fetch).and_return(profile.new)
    # 兼容已发布 0.2.x 与候选解析库的参数错误契约；两者均须在采集前拒绝。
    expect { CtxChecker::RuntimeParser.new(platform: :cisco_nxos) }.to raise_error do |error|
      expect(error).to be_a(ArgumentError).or be_a(KeyError)
    end
  end

  it "rejects invalid model declarations instead of reporting a device parser failure" do
    stub_const("CtxChecker::CiscoNxos::Profile::MODEL_PARSERS", { "broken" => { command => Object } })
    expect { CtxChecker::RuntimeParser.new(platform: :cisco_nxos, model: "broken") }.to raise_error(ArgumentError, /Model parsers/)
  end

  it "does not swallow process cancellation or exit" do
    [ Interrupt, SystemExit ].each do |error|
      allow(implementation).to receive(:parse).and_raise(error)
      expect { parse_resources }.to raise_error(error)
    end
  end
end
