# frozen_string_literal: true

# The validation face (engine validate.h; #882, binding item 6):
# Yeptris::YAML.validate/valid?, the load/load_stream keyword forms,
# the compiled-schema economy, and the Diagnostic value surface.
require "yeptris"
require "yeptris/validation"

RSpec.describe "the validation face (#882)" do
  SCHEMA = '{"type":"object","properties":{"port":{"type":"integer"}},' \
           '"required":["port"]}'.freeze

  describe "Yeptris::YAML.validate with json_schema:" do
    it "answers [] for a valid document against a valid schema" do
      expect(Yeptris::YAML.validate("port: 22\n", json_schema: SCHEMA)).to eq([])
    end

    it "pins every diagnostic field on an invalid document" do
      diags = Yeptris::YAML.validate("port: ssh\n", json_schema: SCHEMA)
      expect(diags.size).to eq(1)
      d = diags.first
      expect(d).to be_a(Yeptris::Validation::Diagnostic)
      expect(d.code).to eq(Yeptris::FFI::DIAG_TYPE)
      expect(d.keyword).to eq("type")
      expect(d.path).to eq("/port")
      expect(d.path_array).to eq(["port"])
      expect(d.detail).to eq("expected integer, got string")
      expect(d.message).to eq(d.detail)
      expect(d.to_s).to eq(d.detail)
      expect(d.line).to eq(1)
      expect(d.col).to eq(7)
      expect(d.offset).to eq(6)
    end

    it "surfaces plain values only — no FFI pointers leak" do
      d = Yeptris::YAML.validate("port: ssh\n", json_schema: SCHEMA).first
      expect(d.path).to be_a(::String)
      expect(d.detail).to be_a(::String)
      expect(d.code).to be_a(::Integer)
      expect(d).not_to be_a(::FFI::Struct)
      expect(d.to_h).to be_a(::Hash)
      expect(d.inspect).to include("type")
    end

    it "reports required misses at the missing key's path" do
      diags = Yeptris::YAML.validate("host: web\n", json_schema: SCHEMA)
      expect(diags.map(&:keyword)).to eq(["required"])
      expect(diags.first.path).to eq("/port")
      expect(diags.first.path_array).to eq(["port"])
    end

    it "escapes ~ and / in path segments (JSON pointer rules)" do
      schema = '{"properties":{"a~b":{"type":"integer"}}}'
      diags = Yeptris::YAML.validate("a~b: x\n", json_schema: schema)
      expect(diags.first.path).to eq("/a~0b")
      expect(diags.first.path_array).to eq(["a~b"])
    end

    it "pins numeric and array keywords with their instance paths" do
      schema = '{"properties":{"list":{"type":"array","items":{"type":"integer"},' \
               '"minItems":2}},"properties2":null}'
      diags = Yeptris::YAML.validate("list: [1]\n", json_schema: schema)
      expect(diags.map(&:keyword)).to eq(["minItems"])
      expect(diags.first.path).to eq("/list")

      diags = Yeptris::YAML.validate("list: [1, two]\n", json_schema: schema)
      expect(diags.map(&:keyword)).to include("type")
      # JSON pointers are 0-based: "two" is element 1
      expect(diags.find { |d| d.keyword == "type" }.path_array).to eq(["list", "1"])
    end

    it "reports the false schema verdict" do
      diags = Yeptris::YAML.validate("k: 1\n", json_schema: "false")
      expect(diags.map(&:keyword)).to eq(["false"])
      expect(diags.first.code).to eq(Yeptris::FFI::DIAG_FALSE_SCHEMA)
    end

    it "validates every document of the stream in one call" do
      stream = "---\nport: 22\n---\nport: ssh\n"
      diags = Yeptris::YAML.validate(stream, json_schema: SCHEMA)
      expect(diags.size).to eq(1)
      expect(diags.first.keyword).to eq("type")
    end

    it "answers [] for the empty stream (trivially valid)" do
      expect(Yeptris::YAML.validate("", json_schema: SCHEMA)).to eq([])
    end

    it "raises ParseError for schema bytes that do not parse" do
      expect do
        Yeptris::YAML.validate("k: 1\n", json_schema: "{oops")
      end.to raise_error(Yeptris::ParseError)
    end

    it "raises ArgumentError for schema bytes holding no document" do
      expect do
        Yeptris::YAML.validate("k: 1\n", json_schema: "")
      end.to raise_error(ArgumentError, /hold no document/)
    end

    it "raises ArgumentError for a json_schema that is neither bytes nor Schema" do
      expect do
        Yeptris::YAML.validate("k: 1\n", json_schema: { type: "object" })
      end.to raise_error(ArgumentError, /json_schema:/)
    end

    it "matches one-shot and compiled verdicts byte for byte" do
      one = Yeptris::YAML.validate("port: ssh\n", json_schema: SCHEMA)
      compiled = Yeptris::Validation::Schema.compile(SCHEMA)
      expect(compiled.validate("port: ssh\n")).to eq(one)
      compiled.free
    end
  end

  describe "the compiled schema (parse once, validate many)" do
    it "validates many streams against one handle" do
      schema = Yeptris::Validation::Schema.compile(SCHEMA)
      expect(schema.valid?("port: 1\n")).to be(true)
      expect(schema.valid?("port: 1\n")).to be(true)
      expect(schema.valid?("port: x\n")).to be(false)
      expect(schema.validate("port: x\n").first.keyword).to eq("type")
      schema.free
    end

    it "compiles YAML-shaped schema mappings (JSON is YAML flow)" do
      schema = Yeptris::Validation::Schema.compile("type: object\nrequired: [port]\n")
      expect(schema.valid?("port: 1\n")).to be(true)
      expect(schema.valid?("host: web\n")).to be(false)
      schema.free
    end

    it "accepts a compiled handle as json_schema:" do
      schema = Yeptris::Validation::Schema.compile(SCHEMA)
      expect(Yeptris::YAML.validate("port: 22\n", json_schema: schema)).to eq([])
      expect(Yeptris::YAML.valid?("port: ssh\n", json_schema: schema)).to be(false)
      schema.free
    end

    it "raises ParseError for schema bytes that do not parse" do
      expect { Yeptris::Validation::Schema.compile("{oops") }
        .to raise_error(Yeptris::ParseError, /schema compile failed/)
    end

    it "raises ArgumentError for empty schema bytes" do
      expect { Yeptris::Validation::Schema.compile("") }
        .to raise_error(ArgumentError, /hold no document/)
      expect { Yeptris::Validation::Schema.compile(nil) }
        .to raise_error(ArgumentError)
    end

    it "frees in the block form on every exit path" do
      freed = nil
      Yeptris::Validation::Schema.open(SCHEMA) do |schema|
        expect(schema.valid?("port: 1\n")).to be(true)
        freed = schema.freed?
      end
      expect(freed).to be(false)
    end

    it "refuses use after free (raised, never a segfault)" do
      schema = Yeptris::Validation::Schema.compile(SCHEMA)
      schema.free
      expect(schema.freed?).to be(true)
      expect { schema.validate("port: 1\n") }.to raise_error(Yeptris::FreedError)
      expect { schema.free }.not_to raise_error # idempotent
    end

    it "is not constructible from a raw pointer" do
      expect { Yeptris::Validation::Schema.new("not a pointer") }
        .to raise_error(ArgumentError, /Schema.compile/)
    end
  end

  describe "Yeptris::YAML.valid?" do
    it "answers the boolean posture of validate" do
      expect(Yeptris::YAML.valid?("port: 22\n", json_schema: SCHEMA)).to be(true)
      expect(Yeptris::YAML.valid?("port: ssh\n", json_schema: SCHEMA)).to be(false)
    end
  end

  describe "the schema-family walk (validate:)" do
    it "pins the duplicate-key diagnostic (canonical-form keys)" do
      diags = Yeptris::YAML.validate("a: 1\na: 2\n", validate: :core_12)
      expect(diags.size).to eq(1)
      expect(diags.first.code).to eq(Yeptris::FFI::DIAG_DUPLICATE_KEY)
      expect(diags.first.keyword).to eq("duplicate-key")
      expect(diags.first.line).to eq(2)
      expect(diags.first.col).to eq(1)
    end

    it "pins the tag-mismatch diagnostic" do
      diags = Yeptris::YAML.validate("a: !!int str\n", validate: :core_12)
      expect(diags.map(&:keyword)).to eq(["tag-mismatch"])
      expect(diags.first.code).to eq(Yeptris::FFI::DIAG_TAG_MISMATCH)
      expect(diags.first.path_array).to eq(["a"])
    end

    it "pins the JSON family's non-json-type diagnostic" do
      # the example-10.8 law (engine #908): implicit no-production
      # plains are STRINGS in the 12_JSON family — `a: yes` validates
      # clean; the diagnostic fires on EXPLICIT non-JSON tags.
      expect(Yeptris::YAML.validate("a: yes\n", validate: :json_12)).to be_empty
      diags = Yeptris::YAML.validate("a: !foo 1\n", validate: :json_12)
      expect(diags.map(&:keyword).uniq).to eq(["non-json-type"])
      expect(diags.first.code).to eq(Yeptris::FFI::DIAG_NON_JSON_TYPE)
    end

    it "accepts a JSON document under the JSON family" do
      expect(Yeptris::YAML.valid?('{"a": [1, 2]}', validate: :json_12)).to be(true)
    end

    it "defaults the walk to core_12" do
      expect(Yeptris::YAML.validate("a: 1\na: 2\n")).not_to be_empty
      expect(Yeptris::YAML.validate("a: 1\n")).to eq([])
    end

    it "refuses :compat_11 — a resolve schema, not a validation family" do
      expect { Yeptris::YAML.validate("a: 1\n", validate: :compat_11) }
        .to raise_error(ArgumentError, /not a validation family/)
    end

    it "raises ArgumentError on an unknown family symbol" do
      expect { Yeptris::YAML.validate("a: 1\n", validate: :nope) }
        .to raise_error(ArgumentError, /schema:/)
    end
  end

  describe "load with the validation keywords" do
    it "loads when valid and raises Validation::Error when not" do
      expect(Yeptris::YAML.load("a: 1\n", validate: true)).to eq("a" => 1)
      expect(Yeptris::YAML.load("port: 22\n", json_schema: SCHEMA)).to eq("port" => 22)

      expect { Yeptris::YAML.load("a: 1\na: 2\n", validate: true) }
        .to raise_error(Yeptris::Validation::Error)
      expect { Yeptris::YAML.load("port: ssh\n", json_schema: SCHEMA) }
        .to raise_error(Yeptris::Validation::Error)
    end

    it "carries the diagnostics on the raised error" do
      begin
        Yeptris::YAML.load("port: ssh\nhost: web\n", json_schema: SCHEMA)
        raise "unreachable"
      rescue Yeptris::Validation::Error => e
        expect(e.diagnostics.map(&:keyword)).to eq(["type"])
        expect(e.diagnostics.first).to be_a(Yeptris::Validation::Diagnostic)
        expect(e.message).to include("type")
        expect(e.message).to include("/port")
      end
    end

    it "keeps the plain load contract when no keyword rides" do
      expect(Yeptris::YAML.load("a: 1\na: 2\n")).to eq("a" => 2) # last wins at parse
    end
  end

  describe "load_stream with the validation keywords" do
    it "raises whole-stream on any document's diagnostics" do
      # the marker-line law (engine #915): `--- a: 1` on ONE line is
      # rejected by libyaml/Psych/PyYAML at 1:6 — the legal multi-doc
      # shape puts the content on the line after the marker.
      expect(Yeptris::YAML.load_stream("---\na: 1\n---\nb: 2\n", validate: true))
        .to eq([{ "a" => 1 }, { "b" => 2 }])

      expect do
        Yeptris::YAML.load_stream("---\na: 1\na: 2\n---\nb: 1\n", validate: :core_12)
      end.to raise_error(Yeptris::Validation::Error) { |e| expect(e.diagnostics.size).to eq(1) }

      expect do
        Yeptris::YAML.load_stream("---\nport: ssh\n", json_schema: SCHEMA)
      end.to raise_error(Yeptris::Validation::Error)
    end
  end

  describe "Document#validate" do
    it "validates the parsed document against a family" do
      doc = Yeptris::Document.parse("a: 1\na: 2\n")
      diags = doc.validate
      expect(diags.map(&:keyword)).to eq(["duplicate-key"])
      expect(diags).to eq(Yeptris::YAML.validate("a: 1\na: 2\n", validate: :core_12))
      doc.free
    end

    it "answers [] for a clean document" do
      doc = Yeptris::Document.parse("a: 1\n")
      expect(doc.validate).to eq([])
      doc.free
    end
  end

  describe "Diagnostic value semantics" do
    it "compares by value and hashes equal" do
      a = Yeptris::Validation::Diagnostic.new(code: 5, path: "/p", detail: "d", line: 1, col: 2)
      b = Yeptris::Validation::Diagnostic.new(code: 5, path: "/p", detail: "d", line: 1, col: 2)
      c = Yeptris::Validation::Diagnostic.new(code: 6, path: "/p", detail: "d", line: 1, col: 2)
      expect(a).to eq(b)
      expect(a).to eql(b)
      expect(a.hash).to eq(b.hash)
      expect(a).not_to eq(c)
      expect([a, b].uniq.size).to eq(1)
    end

    it "names every engine keyword (the head of the enum is pinned)" do
      expect(Yeptris::Validation::KEYWORD[Yeptris::FFI::DIAG_TYPE]).to eq("type")
      expect(Yeptris::Validation::KEYWORD[Yeptris::FFI::DIAG_DEPENDENT_REQUIRED])
        .to eq("dependentRequired")
      expect(Yeptris::Validation::Diagnostic.new(code: 9999, path: "", detail: "").keyword)
        .to eq("unknown-9999")
    end
  end
end
