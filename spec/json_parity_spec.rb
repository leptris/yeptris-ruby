# frozen_string_literal: true

# TODO.restructure/31 — the strict-JSON surface's PARITY SPEC.
#
# `Yeptris::JSON.load` must equal `JSON.parse` on every value and
# every error case, on whichever engine is loaded (native when the
# extension is built, the record-drain fallback otherwise). Defaults
# on the YAML surface never flip on benchmark claims alone — this
# spec plus benchmark/json_profile.rb are the proof required.

require "json"

RSpec.describe "Yeptris::JSON parity with JSON.parse" do
  VALUES = [
    "null",
    "true",
    "false",
    "0",
    "-0",
    "42",
    "-9223372036854775808",
    "9223372036854775807",
    "9223372036854775808",
    "12345678901234567890123",
    "1.5",
    "-0.25",
    "1e3",
    "1E+3",
    "2.5e-8",
    "0.1",
    %q("hello"),
    %q(""),
    %q("with \\"escape\\" and \\n newline"),
    %q("unicode: café ☕ 𝄞"),
    "[]",
    "{}",
    "[1, 2.5, true, null, \"s\"]",
    "{\"id\":1,\"name\":\"x\",\"tags\":[\"a\",\"b\"]}",
    "[{\"a\":1},{\"b\":[2,3]},[[4]]]",
    "{\"a\":{\"b\":{\"c\":[{}]}}}",
    "{\"dup\":1,\"dup\":2}",
    "  [ 1 , 2 ]  ",
    "\n\t{\n\"k\"\n:\n1}\n",
  ].freeze

  ERRORS = [
    "",
    "not json",
    "[1,]",
    "{\"a\" 1}",
    "{\"a\":}",
    "[1 2]",
    "'single'",
    "{a:1}",
    "01",
    "1.",
    ".5",
    "1e",
    "+1",
    "NaN",
    "Infinity",
    %q({"a":1} trailing),
    "[",
    "\"unterminated",
    "{\"a\":\"\\u12\"}",
    "true false",
  ].freeze

  def parse_with_json_gem(text)
    JSON.parse(text)
  rescue JSON::ParserError
    :parse_error
  end

  def parse_with_yeptris(text)
    Yeptris::JSON.load(text)
  rescue Yeptris::JSON::ParseError, Yeptris::ParseError
    :parse_error
  end

  describe "values" do
    VALUES.each do |json|
      it "equals JSON.parse on #{json.inspect[0, 50]}" do
        expected = parse_with_json_gem(json)
        actual = parse_with_yeptris(json)
        expect(actual).to eq(expected)
      end
    end
  end

  describe "errors" do
    ERRORS.each do |json|
      it "rejects what JSON.parse rejects: #{json.inspect[0, 40]}" do
        expected = parse_with_json_gem(json)
        actual = parse_with_yeptris(json)
        expect(actual).to eq(:parse_error), "yeptris accepted #{json.inspect}"
      end
    end
  end

  describe "engines agree" do
    it "the fallback engine matches the native engine (when both exist)" do
      skip "native extension not loaded" unless defined?(Yeptris::Native)

      VALUES.each do |json|
        native = Yeptris::Native.load_json(json)
        fallback = Yeptris::JSON.strict_fallback(json)
        expect(fallback).to eq(native), json
      end
    end
  end

  describe "types" do
    it "1e3 is a Float (the JSON contract, NOT the Psych String)" do
      expect(Yeptris::JSON.load("[1e3]")[0]).to be_a(Float).and eq(1000.0)
    end

    it "integer-beyond-int64 is an exact Integer (Bignum)" do
      expect(Yeptris::JSON.load("[9223372036854775808]")).to eq([9_223_372_036_854_775_808])
    end

    it "strings are UTF-8" do
      s = Yeptris::JSON.load(%q(["café"]))[0]
      expect(s.encoding).to eq(Encoding::UTF_8)
    end
  end

  describe "the YAML surface keeps the Psych contract (default-safety)" do
    it "JSON-shaped YAML with a trailing comma parses like Psych" do
      expect(Yeptris::YAML.load('{"a": [1,]}')).to eq({ "a" => [1] })
    end

    it "'1e3' as YAML is a Psych String, not a Float" do
      expect(Yeptris::YAML.load('{"a": 1e3}')).to eq({ "a" => "1e3" })
    end

    it "YAML.load never silently switches engines by input shape" do
      # the same bytes, two surfaces, two honest contracts
      json_text = '{"a": 1e3}'
      expect(Yeptris::YAML.load(json_text)).to eq({ "a" => "1e3" })
      expect(Yeptris::JSON.load(json_text)).to eq({ "a" => 1000.0 })
    end
  end
end
