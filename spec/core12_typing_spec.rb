# frozen_string_literal: true

# TODO.restructure/32 — core_12 typing follows the spec table, not the
# Psych quirk. The table below is spec 10.3.2 / Example 10.9 VERBATIM
# (docs/spec/yaml-grammar-citations.md pins the source); compat_11
# keeps Psych's behavior byte-identical (the ported Psych suite is the
# compat gate).

RSpec.describe "core_12 scalar typing (spec 10.3.2)" do
  # Example 10.9, the JSON-equivalent column
  SPEC_TABLE = {
    "null" => nil,
    "" => nil,          # empty scalar
    '""' => "",
    "true" => true,
    "True" => true,
    "false" => false,
    "FALSE" => false,
    "0" => 0,
    "0o7" => 7,
    "0x3A" => 58,
    "-19" => -19,
    "0." => 0.0,
    "-0.0" => -0.0,
    ".5" => 0.5,
    "+12e03" => 12_000.0,
    "-2E+05" => -200_000.0,
    "1e3" => 1000.0,
    ".inf" => :inf,
    "-.Inf" => :neg_inf,
    ".NAN" => :nan,
  }.freeze

  def load_scalar(text, schema)
    Yeptris::YAML.load("k: #{text}\n", schema: schema)["k"]
  rescue StandardError
    :error
  end

  describe "the value surface (YAML.load)" do
    it "matches the spec table under core_12" do
      SPEC_TABLE.each do |text, want|
        got = load_scalar(text, :core_12)
        case want
        when :nan then expect(got.to_s).to eq("NaN"), text
        when :inf then expect(got).to eq(Float::INFINITY), text
        when :neg_inf then expect(got).to eq(-Float::INFINITY), text
        else expect(got).to eq(want), "core_12 #{text.inspect}: got #{got.inspect}"
        end
      end
    end

    it "keeps Psych typing under compat_11 (spot table)" do
      # Psych's float requires the dot; 1.1 octal is 0N, not 0oN
      expect(load_scalar("1e3", :compat_11)).to eq("1e3")
      expect(load_scalar("+12e03", :compat_11)).to eq("+12e03")
      expect(load_scalar("0o7", :compat_11)).to eq("0o7")
      expect(load_scalar("0x3A", :compat_11)).to eq(58)
      expect(load_scalar("0.", :compat_11)).to eq(0.0)
    end
  end

  describe "the Node surface (Document#to_ruby)" do
    it "is schema-conditioned like the value surface" do
      core = Yeptris::Document.parse("k: 1e3\n", schema: :core_12)
      compat = Yeptris::Document.parse("k: 1e3\n", schema: :compat_11)
      expect(core.root["k"].to_ruby).to eq(1000.0)
      expect(compat.root["k"].to_ruby).to eq("1e3")
      expect(core.parse_schema).to eq(:core_12)
      expect(compat.parse_schema).to eq(:compat_11)
      core.free
      compat.free
    end

    it "parse_json documents are core by construction" do
      doc = Yeptris::Document.parse_json('{"a": 1e3}')
      expect(doc.parse_schema).to eq(:core_12)
      doc.free
    end
  end

  describe "the surfaces agree per schema" do
    it "1e3 is Float on JSON + core_12 YAML, String on compat_11 YAML" do
      expect(Yeptris::JSON.load('{"a": 1e3}')).to eq({ "a" => 1000.0 })
      expect(Yeptris::YAML.load('{"a": 1e3}', schema: :core_12)).to eq({ "a" => 1000.0 })
      expect(Yeptris::YAML.load('{"a": 1e3}', schema: :compat_11)).to eq({ "a" => "1e3" })
    end
  end
end
