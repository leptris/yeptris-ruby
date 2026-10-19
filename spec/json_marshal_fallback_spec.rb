# frozen_string_literal: true

# yeptris-ruby#278 — the marshal engine: the JSON fallback wired
# through yeptris_parse_json + yeptris_marshal_node(_ex) + ONE core
# Marshal.load. The pure-Ruby record walk measured 0.11x vs
# JSON.parse on real-world documents when no Ruby-version-matched
# native build exists; this route keeps the work C-side end to end.
# The parity target is unchanged: exact JSON.parse semantics on
# whichever engine is loaded.

require "json"

RSpec.describe "Yeptris::JSON marshal fallback" do
  def marshal_available?
    defined?(::Yeptris::FFI::MARSHAL_STRICT_DUP) && ::Yeptris::FFI::MARSHAL_STRICT_DUP
  end

  describe "value parity (the marshal route vs JSON.parse)" do
    VALUES = [
      "null", "true", "false",
      "0", "-0", "42", "-42",
      "-9223372036854775808", "9223372036854775807", "9223372036854775808",
      "12345678901234567890123",
      "1.5", "-0.25", "1e3", "2.5e-8", "0.1",
      %q("hello"), %q(""), %q("with \"escape\" and \n newline"),
      %q("unicode: café ☕ 𝄞"),
      "[]", "{}",
      "[1, 2.5, true, null, \"s\"]",
      "{\"id\":1,\"name\":\"x\",\"tags\":[\"a\",\"b\"]}",
      "[{\"a\":1},{\"b\":[2,3]},[[4]]]",
      "{\"a\":{\"b\":{\"c\":[{}]}}}",
    ].freeze

    it "equals JSON.parse on every value shape" do
      skip "marshal engine unavailable" unless marshal_available?
      VALUES.each do |json|
        expect(Yeptris::JSON.marshal_engine(json, 0)).to eq(JSON.parse(json)), json
      end
    end

    it "keeps strings UTF-8 and big ints exact" do
      skip "marshal engine unavailable" unless marshal_available?
      s = Yeptris::JSON.marshal_engine(%q(["café"]), 0)[0]
      expect(s.encoding).to eq(Encoding::UTF_8)
      expect(Yeptris::JSON.marshal_engine("[9223372036854775808]", 0))
        .to eq([9_223_372_036_854_775_808])
      expect(Yeptris::JSON.marshal_engine("[1e3]", 0)[0]).to be_a(Float).and eq(1000.0)
    end
  end

  describe "duplicate keys" do
    it "raises ParseError under json 3 (strict is the resolved default)" do
      skip "marshal engine unavailable" unless marshal_available?
      if Yeptris::JSON::STRICT_DUPLICATE_KEYS
        expect { Yeptris::JSON.marshal_engine('{"a":1,"a":2}', 1) }
          .to raise_error(Yeptris::JSON::ParseError)
        expect { Yeptris::JSON.marshal_engine('{"x":{"k":1,"k":2}}', 1) }
          .to raise_error(Yeptris::JSON::ParseError)
      end
    end

    it "stays last-wins when the strict flag is clear (json 2.x contract)" do
      skip "marshal engine unavailable" unless marshal_available?
      expect(Yeptris::JSON.marshal_engine('{"a":1,"a":2}', 0)).to eq({"a" => 2})
    end

    it "strict_fallback follows the resolved json gem" do
      skip "marshal engine unavailable" unless marshal_available?
      if Yeptris::JSON::STRICT_DUPLICATE_KEYS
        expect { Yeptris::JSON.strict_fallback('{"a":1,"a":2}') }
          .to raise_error(Yeptris::JSON::ParseError)
      else
        expect(Yeptris::JSON.strict_fallback('{"a":1,"a":2}')).to eq({"a" => 2})
      end
    end
  end

  describe "errors" do
    it "raises ParseError on what JSON.parse rejects" do
      skip "marshal engine unavailable" unless marshal_available?
      ["{a: 1}", "[1,]", "{\"a\" 1}", "[1 2]", ""].each do |json|
        expect { Yeptris::JSON.marshal_engine(json, 0) }
          .to raise_error(Yeptris::JSON::ParseError), json
      end
    end
  end

  describe "the load ladder" do
    it "returns the same values the native route would (document shape)" do
      skip "marshal engine unavailable" unless marshal_available?
      doc = {"definitions" => {"p" => {"type" => "object"}},
             "paths" => {"/x" => {"get" => {"responses" => {"200" => {}}}}}}
      json = JSON.dump(doc)
      expect(Yeptris::JSON.marshal_engine(json, 0)).to eq(doc)
      expect(Yeptris::JSON.load(json)).to eq(doc)
    end
  end
end
