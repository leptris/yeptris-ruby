# frozen_string_literal: true

RSpec.describe Yeptris do
  it "reports the library version" do
    expect(Yeptris::FFI.yeptris_version).to match(/\A\d+\.\d+\.\d+\z/)
  end

  it "requires without side effects beyond FFI attach" do
    expect(defined?(Yeptris::YAML)).to be_truthy
  end
end

RSpec.describe Yeptris::Document do
  it "parses and serializes round-trip" do
    doc = described_class.parse("a: 1\nb: [x, y]\n")
    expect(doc.document_count).to eq(1)
    expect(doc.serialize).to eq("a: 1\nb: [x, y]\n")
    doc.free
  end

  it "raises ParseError with line/column on bad input" do
    expect { described_class.parse("a: [1,\n  b: 2\n") }
      .to raise_error(Yeptris::ParseError, /line \d+/)
  end

  it "raises FreedError after free, never segfaults" do
    doc = described_class.parse("a: 1\n")
    node = doc.root
    doc.free
    expect { node.value }.to raise_error(Yeptris::FreedError)
    expect { doc.serialize }.to raise_error(Yeptris::FreedError)
  end

  it "supports parse_json and JSON serialization" do
    doc = described_class.parse_json('{"a": [1, 2.5, true, null, "s"]}')
    expect(doc.serialize_json).to eq("{\"a\": [1, 2.5, true, null, \"s\"]}\n")
    doc.free
  end

  it "builds documents from scratch and serializes them" do
    doc = described_class.create
    root = doc.new_mapping
    doc.set_root(root)
    seq = doc.new_sequence
    root.map_add("list", seq)
    seq.seq_add(doc.new_scalar("1"))
    seq.seq_add(doc.new_scalar("2", :double_quoted))
    expect(doc.serialize).to eq("list:\n  - 1\n  - \"2\"\n")
    doc.free
  end
end

RSpec.describe Yeptris::Node do
  # compat_11: Psych semantics (timestamp + y/n typing are 1.1)
  let(:doc) { Yeptris::Document.parse(<<~YAML, schema: :compat_11) }
    name: yeptris
    count: 42
    ratio: 2.5
    active: true
    missing: ~
    tags:
      - yaml
      - c11
    nested:
      inner: value
    anchored: &a
      x: 1
    alias: *a
    date: 2026-09-02
  YAML

  after { doc.free }

  it "preserves wrapper identity" do
    expect(doc.root["tags"].seq_at(0)).not_to be_nil
    n1 = doc.root["tags"]
    n2 = doc.root["tags"]
    expect(n1).to equal(n2)
    expect(doc.root).to equal(doc.root)
  end

  it "exposes kinds, values, styles" do
    root = doc.root
    expect(root).to be_mapping
    expect(root["tags"]).to be_sequence
    expect(root["name"]).to be_scalar
    expect(root["name"].value).to eq("yeptris")
    expect(root["name"].style).to eq(:plain)
  end

  it "reads typed scalars" do
    expect(doc.root["count"].to_i).to eq(42)
    expect(doc.root["ratio"].to_f).to eq(2.5)
    expect(doc.root["active"].to_bool).to be(true)
  end

  it "resolves aliases to the target node" do
    alias_node = doc.root["alias"]
    expect(alias_node).to be_alias
    expect(alias_node.alias_target["x"].to_i).to eq(1)
  end

  it "walks mappings and sequences" do
    tags = doc.root["tags"]
    expect(tags.map(&:value)).to eq(%w[yaml c11])
    expect(doc.root.keys.map(&:value)).to include("name", "nested")
    inner = doc.root["nested"]
    expect(inner.map_count).to eq(1)
  end

  it "materializes Psych-compatible Ruby objects" do
    obj = doc.to_ruby
    expect(obj).to eq(
      "name" => "yeptris",
      "count" => 42,
      "ratio" => 2.5,
      "active" => true,
      "missing" => nil,
      "tags" => %w[yaml c11],
      "nested" => { "inner" => "value" },
      "anchored" => { "x" => 1 },
      "alias" => { "x" => 1 },
      "date" => Date.new(2026, 9, 2)
    )
  end

  it "preserves alias object identity when materializing" do
    obj = doc.to_ruby
    expect(obj["alias"]).to equal(obj["anchored"])
  end

  it "scans :symbol keys and values like Psych" do
    d = Yeptris::Document.parse(":name: :value\nplain: text\n", schema: :compat_11)
    obj = d.to_ruby
    expect(obj).to eq(name: :value, "plain" => "text")
    d.free
  end
end

RSpec.describe Yeptris::YAML do
  it "loads with compat typing by default (Psych-verified)" do
    expect(described_class.load("flag: yes\nnum: 017\n"))
      .to eq("flag" => true, "num" => 15)
    expect(described_class.load("num: 0o17\n")).to eq("num" => "0o17")
  end

  it "matches Psych's boolean words exactly (no single-char y/n)" do
    expect(described_class.load("yes: 1\noff: 2\nOn: 3\nyES: 4\n"))
      .to eq(true => 1, false => 2, true => 3, true => 4)
    expect(described_class.load("n: 1\ny: 2\n")).to eq("n" => 1, "y" => 2)
  end

  it "loads with core 1.2 typing on request" do
    expect(described_class.load("flag: yes\n", schema: :core_12))
      .to eq("flag" => "yes")
    expect(described_class.load("flag: yes\n", schema: :compat_11))
      .to eq("flag" => true)
  end

  it "resolves merge keys like Psych (existing keys win)" do
    yaml = <<~Y
      base: &b
        a: 1
        b: 2
      merged:
        <<: *b
        b: 20
    Y
    expect(described_class.load(yaml)["merged"]).to eq("a" => 1, "b" => 20)
  end

  it "load_stream returns every document" do
    expect(described_class.load_stream("--- 1\n--- 2\n")).to eq([1, 2])
  end

  it "dumps scalars round-trip" do
    expect(described_class.dump("plain")).to eq("plain\n")
    expect(described_class.dump("12")).to eq("\"12\"\n")
    expect(described_class.dump(42)).to eq("42\n")
    expect(described_class.dump(2.5)).to eq("2.5\n")
    expect(described_class.dump(true)).to eq("true\n")
    expect(described_class.dump(nil)).to eq("null\n")
  end

  it "dumps structures round-trip" do
    obj = { "name" => "yeptris", "tags" => %w[yaml c11], "nested" => { "x" => 1 } }
    expect(described_class.load(described_class.dump(obj))).to eq(obj)
  end

  it "dumps symbols round-trip" do
    expect(described_class.load(described_class.dump({name: :value}))).to eq(name: :value)
  end

  it "dumps dates round-trip" do
    expect(described_class.load(described_class.dump(Date.new(2026, 9, 2))))
      .to eq(Date.new(2026, 9, 2))
  end

  it "refuses recursive structures instead of hanging" do
    h = {}
    h["self"] = h
    expect { described_class.dump(h) }.to raise_error(Yeptris::DumpError, /cycle/)
  end

  it "round-trips via GC without leaks (finalizer path)" do
    200.times { described_class.load("a: [1, 2, 3]\n") }
    GC.start
    expect(described_class.load("ok: yes\n")).to eq("ok" => true)
  end
end

require "stringio"

RSpec.describe "Yeptris.read_input (the typed input boundary)" do
  before(:all) { require "yeptris" }

  it "passes Strings through unchanged" do
    s = "k: v"
    expect(Yeptris.read_input(s)).to equal(s)
  end

  it "reads IO objects" do
    expect(Yeptris.read_input(StringIO.new("k: v"))).to eq("k: v")
    expect(Yeptris.read_input(File.open(__FILE__))).to start_with("#")
  end

  it "stringifies anything else (the documented fallback)" do
    expect(Yeptris.read_input(:sym)).to eq("sym")
    expect(Yeptris.read_input(42)).to eq("42")
  end

  it "feeds every entry point" do
    expect(Yeptris::YAML.load(StringIO.new("k: v"))).to eq("k" => "v")
    expect(Yeptris::Document.parse(StringIO.new("k: v")).document_count).to eq(1)
  end
end
