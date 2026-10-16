# frozen_string_literal: true

require_relative "spec_helper"
require "ctx_checker"

RSpec.describe CtxChecker::RuntimeParser do
  let(:parser) { described_class.new(platform: "iosxe") }

  it "normalizes aliases and rejects unknown platform or dimension" do
    expect(parser.platform).to eq("cisco_ios")
    expect { described_class.new(platform: "unknown") }.to raise_error(ArgumentError)
    expect { parser.parse(:script, "show anything") }.to raise_error(ArgumentError)
    expect { parser.parse_many(%i[interfaces bgp], "") }.to raise_error(ArgumentError)
  end

  it "keeps incomplete, invalid, empty and unsupported outputs distinct" do
    body = "GigabitEthernet1/0/1 is up, line protocol is up\n"
    expect(parser.parse(:interfaces, body).status).to eq(:partial)
    expect(parser.parse(:interfaces, "\x00", complete: true).issues).to include(include(code: :invalid_output, stage: :parse, error_type: "ArgumentError"))
    expect(parser.parse(:interfaces, "", complete: true).status).to eq(:failed)
    expect(parser.parse(:interfaces, "% Invalid input detected\n", complete: true).status).to eq(:unsupported)
  end

  it "reports terminal pagination as incomplete even with otherwise valid records" do
    body = "GigabitEthernet1/0/1 is up, line protocol is up\n--More--\n"
    result = parser.parse(:interfaces, body, complete: true)
    expect(result.status).to eq(:partial)
    expect(result.issues).to include(include(code: :paginated_output))
  end

  it "keeps raw outputs out of evidence and isolates parsed records from caller mutations" do
    text = +"GigabitEthernet1/0/1 is up, line protocol is up\n"
    result = parser.parse(:interfaces, text, complete: true)
    text.replace("password")
    expect(result.evidence.first.keys).to contain_exactly(:command, :sha256, :bytes, :status)
    expect(result.records.first).to be_frozen
    expect(result.to_h.to_s).not_to include("line protocol", "password")
  end

  it "does not mistake interface descriptions for command errors" do
    body = "GigabitEthernet1/0/1 is up, line protocol is up\n  Description: Unknown command test link\n"
    expect(parser.parse(:interfaces, body, complete: true).status).to eq(:complete)
  end

  it "rejects terminal control bytes before untrusted names reach record validation" do
    [ "\e[31m", "\b", "\x7f" ].each do |control|
      body = "GigabitEthernet1/0/1#{control} is up, line protocol is up\n"
      result = parser.parse(:interfaces, body, complete: true)
      expect(result.status).to eq(:failed)
      expect(result.issues).to include(include(code: :invalid_output, stage: :parse, error_type: "ArgumentError"))
      expect(result.records).to be_empty
    end
  end
end
