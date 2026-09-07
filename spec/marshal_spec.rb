# frozen_string_literal: true

require "psych"

# TODO.restructure/21 — the Marshal fast path's semantic gate: for
# every input, the Marshal-loaded object graph must equal the record
# walk's graph (the two paths share the value records; this spec pins
# the materialization semantics together). Falls back to the walk on
# UNSUPPORTED (merge keys, timestamps) — that boundary is pinned too.

RSpec.describe "Marshal fast path" do
  CORPUS = [
    "a: 1",
    "[]",
    "{}",
    "- 1\n- two\n",
    "k: &anc hello\nj: *anc\n",
    "n: -9223372036854775808",
    "small: -123\nneg: -1\nzero: 0\n",
    "f: [0.1, 1.5, -0.25, 1e30]",
    "e: 1e3",
    "sym: :name\nqs: ':quoted'\n",
    "deep:\n  a:\n    b:\n      c: [1, 2, {d: e}]",
    "{\"id\":1,\"name\":\"x\",\"tags\":[\"a\",\"b\"],\"meta\":{\"v\":2.5,\"ok\":true}}",
    "[{\"a\":1},{\"b\":[2,3]},[[4]]]",
    "unicode: café ☕",
    "multi-line: |\n  line one\n  line two\n",
    "empty_string: \"\"\nempty_map: {}\nempty_seq: []\n",
    "long_string: #{'x' * 500}",
    "--- 1\n--- 2\n--- 3",
    "---\n",
    "a: 200\nb: 3000\nc: 123456789\nd: 1234567890123456789",
    "floats: [2.5e-8, 1.7976931348623157e+308, 4.9e-324]",
  ].freeze

  def walk_reference(yaml)
    # the columnar walk is the semantic reference (the fallback path)
    schema = :compat_11
    yaml_input = yaml
    cols = Yeptris::FFI::ValueColumns.new
    st = Yeptris::FFI.yeptris_value_drain_columns(
      yaml_input, yaml_input.bytesize,
      Yeptris::FFI::SCHEMA_11_COMPAT, cols
    )
    raise "drain failed: #{Yeptris::FFI.last_error_message}" if st != Yeptris::FFI::OK

    begin
      n = cols[:count]
      kinds = cols[:kinds].read_bytes(n).unpack("C*")
      tags = cols[:tags].read_bytes(n).unpack("C*")
      ikeys = cols[:is_keys].read_bytes(n).unpack("C*")
      bools = cols[:bools].read_bytes(n).unpack("C*")
      offs = cols[:offs].read_bytes(n * 4).unpack("V*")
      lens = cols[:lens].read_bytes(n * 4).unpack("V*")
      pays = cols[:payloads].read_bytes(n * 8).unpack("q<*")
      arena = cols[:arena].read_bytes(cols[:arena_len]).force_encoding(Encoding::UTF_8)
      Yeptris::ValueML.walk_columns(kinds, tags, ikeys, bools, offs, lens, pays, arena)
    ensure
      Yeptris::FFI.yeptris_value_free_columns(cols)
    end
  end

  describe "load equivalence" do
    CORPUS.each do |yaml|
      it "materializes #{yaml.inspect[0, 50]} like the walk" do
        one = Yeptris::ValueML.load_all_marshal(yaml, mode: :first)
        all = Yeptris::ValueML.load_all_marshal(yaml, mode: :all)
        if one.nil? # UNSUPPORTED: the walk is the answer
          expect(Yeptris::YAML.load(yaml)).to eq(walk_reference(yaml).first)
        else
          expect(one).to eq(walk_reference(yaml).first)
          expect(all).to eq(walk_reference(yaml))
        end
      end
    end
  end

  describe "fallback boundary" do
    it "falls back on merge keys" do
      yaml = "base: &b {a: 1}\nsub:\n  <<: *b\n  c: 2\n"
      expect(Yeptris::ValueML.load_all_marshal(yaml, mode: :first)).to be_nil
      expect(Yeptris::YAML.load(yaml)["sub"]).to eq({ "a" => 1, "c" => 2 })
    end

    it "falls back on timestamps" do
      yaml = "d: 2026-09-02\n"
      expect(Yeptris::ValueML.load_all_marshal(yaml, mode: :first)).to be_nil
      expect(Yeptris::YAML.load(yaml)["d"]).to be_a(Date) # date-only: Date, not Time
    end
  end

  describe "identity semantics" do
    it "shares alias objects (object links)" do
      obj = Yeptris::YAML.load(<<~YAML)
        ---
        - &id001
          a: 1
        - *id001
        - *id001
      YAML
      expect(obj[1]).to equal(obj[0])
      expect(obj[2]).to equal(obj[0])
    end

    it "shares aliased strings and maps through Document#to_ruby" do
      doc = Yeptris::Document.parse("a: &x {k: 1}\nb: *x\nc: *x\n")
      obj = doc.to_ruby
      expect(obj["b"]).to equal(obj["a"])
      expect(obj["c"]).to equal(obj["a"])
      doc.free
    end

    it "re-materializes consistently on readonly documents" do
      doc = Yeptris::Document.parse("a: &x {k: 1}\nb: *x\n").readonly!
      first = doc.root.to_ruby
      again = doc.root.to_ruby
      expect(again).to equal(first)
    end
  end

  describe "encoding" do
    it "produces UTF-8 strings" do
      obj = Yeptris::YAML.load("s: café ☕\n")
      expect(obj["s"].encoding).to eq(Encoding::UTF_8)
      expect(obj["s"]).to eq("café ☕")
    end

    it "produces UTF-8 keys" do
      obj = Yeptris::YAML.load("ключ: значение\n")
      expect(obj.keys.first.encoding).to eq(Encoding::UTF_8)
    end
  end

  describe "Psych::VERSION surface compatibility" do
    it "loads what Psych dumps" do
      x = { "a" => [1, 2.5, true, nil, "s"], "b" => { "c" => "d" } }
      expect(Yeptris::YAML.load(Psych.dump(x))).to eq(x)
    end
  end
end
