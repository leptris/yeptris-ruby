# frozen_string_literal: true

# The canon parity issues (TODO.restructure/43): every case pins
# yeptris against the REFERENCE's own behavior (Psych / the resolved
# json gem) — the same gate lutaml/canon's engine switch uses.

require "json"

RSpec.describe "canon parity (issues #29-#37)" do
  # rebind at EXAMPLE time like psych_compat_spec — a load-time
  # require breaks the stdlib-psych load order other specs need
  before(:all) { require "yeptris/psych" }

  # Oracle values are PINNED LITERALS, transcribed from the stdlib's
  # own behavior (psych/scalar_scanner.rb's weight-based sexagesimal
  # fold; Psych.safe_load's empty-doc nil) — the rebind makes an
  # in-process Psych oracle impossible (the stdlib's internals
  # resolve the rebound constant), and the C suite pins the same
  # table (Compat11.PsychSexagesimalWeights).

  describe "#29 empty and comment-only documents" do
    it "return nil like Psych.safe_load" do
      ["", "\n", "# just a comment\n", "---\n# only a comment\n"].each do |doc|
        expect(Yeptris::YAML.load(doc)).to be_nil, doc.inspect
      end
    end
  end

  describe "#30 Psych's sexagesimal weights" do
    it "2-component is H:M (seconds implicitly zero)" do
      { "a: 1:30\n" => 5400, "a: -1:30\n" => -1800, "a: 0:30\n" => 1800,
        "a: 1:30.5\n" => 5430.0 }.each do |yaml, want|
        expect(Yeptris::YAML.load(yaml)["a"]).to eq(want), yaml
      end
    end

    it "3-component is H:M:S" do
      { "a: 190:20:30\n" => 685230, "a: 190:20:30.15\n" => 685230.15,
        "a: 1:2:3\n" => 3723 }.each do |yaml, want|
        expect(Yeptris::YAML.load(yaml)["a"]).to eq(want), yaml
      end
    end
  end

  describe "#31 integers beyond int64" do
    it "materialize as Integer like Psych" do
      { "a: 12345678901234567890123\n" => 12_345_678_901_234_567_890_123,
        "a: 99999999999999999999999999999999\n" => 99_999_999_999_999_999_999_999_999_999_999,
        "a: -12345678901234567890123\n" => -12_345_678_901_234_567_890_123,
        "a: 999_999_000_000_000_000_000_000\n" => 999_999_000_000_000_000_000_000 }.each do |yaml, want|
        got = Yeptris::YAML.load(yaml)
        expect(got["a"]).to be_an(Integer), yaml
        expect(got["a"]).to eq(want), yaml
      end
    end

    it "leading zeros stay Strings like Psych" do
      expect(Yeptris::YAML.load("a: 012345678901234567890123\n")["a"]).to be_a(String)
    end

    it "every surface agrees" do
      yaml = "a: 12345678901234567890123\n"
      expect(Yeptris::YAML.load(yaml)["a"]).to be_an(Integer)
      expect(Yeptris::ValueML.load_all(yaml).first["a"]).to be_an(Integer)
      doc = Yeptris::Document.parse(yaml)
      expect(doc.root["a"].to_ruby).to be_an(Integer)
      doc.free
    end
  end

  describe "#37 duplicate JSON keys follow the resolved json gem" do
    dup = '{"a":1,"a":2}'
    nested = '[{"x":1,"x":2}]'

    it "the strictness verdict matches JSON.parse" do
      begin
        JSON.parse(dup)
        stdlib_raises = false
      rescue JSON::ParserError
        stdlib_raises = true
      end
      expect(Yeptris::JSON::STRICT_DUPLICATE_KEYS).to eq(stdlib_raises)
    end

    it "raises with the duplicate key named (native engine)" do
      if Yeptris::JSON::STRICT_DUPLICATE_KEYS
        expect { Yeptris::JSON.load(dup) }
          .to raise_error(Yeptris::JSON::ParseError, /duplicate key "a"/)
        expect { Yeptris::JSON.load(nested) }
          .to raise_error(Yeptris::JSON::ParseError, /duplicate key "x"/)
      else
        expect(Yeptris::JSON.load(dup)).to eq("a" => 2) # json 2.x: last-wins
      end
    end

    it "the strict fallback agrees with the native engine" do
      if Yeptris::JSON::STRICT_DUPLICATE_KEYS
        expect { Yeptris::JSON.strict_fallback(dup) }
          .to raise_error(Yeptris::JSON::ParseError, /duplicate key "a"/)
      else
        expect(Yeptris::JSON.strict_fallback(dup)).to eq("a" => 2)
      end
    end

    it "distinct keys parse normally" do
      expect(Yeptris::JSON.load('{"a":1,"b":2}')).to eq("a" => 1, "b" => 2)
    end
  end

  describe "#32 Psych::SyntaxError-compatible surface" do
    it "has Psych's constructor arity, readers and message shape" do
      e = Psych::SyntaxError.new("f.yml", 3, 7, 21, "could not find expected ':'", "while scanning")
      expect(e.message).to eq("(f.yml): could not find expected ':' while scanning at line 3 column 7")
      expect([e.file, e.line, e.column, e.offset, e.problem, e.context])
        .to eq(["f.yml", 3, 7, 21, "could not find expected ':'", "while scanning"])
    end

    it "parses carry line/column from the C parser" do
      expect { Psych.parse("a: [1,") }.to raise_error(Psych::SyntaxError) { |err|
        expect(err.line).to be_positive
        expect(err.problem).to be_a(String)
      }
    end
  end
end
