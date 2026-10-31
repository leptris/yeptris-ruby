# frozen_string_literal: true

require "psych"

RSpec.describe "Psych.load options" do
  # stdlib parity: load forwarded symbolize_names/fallback to
  # safe_load, and the ** swallowed both silently (audit 2026-10-31)

  it "symbolize_names rides load" do
    expect(Yeptris::Psych.load("a: 1\nb: [x]\n", symbolize_names: true))
      .to eq(a: 1, b: ["x"])
  end

  it "fallback answers for an empty stream" do
    expect(Yeptris::Psych.load("", fallback: 42)).to eq(42)
  end

  it "fallback does not shadow documents whose content is nil" do
    # documents exist; stdlib returns their nil content
    expect(Yeptris::Psych.load("---\n", fallback: 42)).to be_nil
    expect(Yeptris::Psych.load("---\n---\n", fallback: 42)).to be_nil
  end

  it "safe_load keeps its symbolize_names behavior" do
    expect(Yeptris::Psych.safe_load("k: v\n", symbolize_names: true))
      .to eq(k: "v")
  end
end

RSpec.describe "event-level scalar encodings" do
  # the parser's arena rode ASCII-8BIT; stdlib Psych hands handlers
  # UTF-8 and TreeBuilder propagates it into node values
  # (audit 2026-10-31)

  it "hands handler scalars as UTF-8" do
    got = []
    handler = Object.new
    handler.define_singleton_method(:event_location) { |*| }
    handler.define_singleton_method(:start_stream) { |*| }
    handler.define_singleton_method(:end_stream) { |*| }
    handler.define_singleton_method(:start_document) { |*| }
    handler.define_singleton_method(:end_document) { |*| }
    handler.define_singleton_method(:start_sequence) { |*| }
    handler.define_singleton_method(:end_sequence) { |*| }
    handler.define_singleton_method(:start_mapping) { |*| }
    handler.define_singleton_method(:end_mapping) { |*| }
    handler.define_singleton_method(:alias) { |*| }
    handler.define_singleton_method(:scalar) do |value, *_rest|
      got << value
    end
    Yeptris::Psych::Parser.new(handler).parse("a: caf\xc3\xa9\n")
    expect(got).to include("café")
    expect(got.map(&:encoding).uniq).to eq([Encoding::UTF_8])
  end

  it "TreeBuilder node values carry UTF-8" do
    tree = ::Psych.parse("a: caf\xc3\xa9\n")
    v = tree.children.first.children.last.value
    expect(v).to eq("café")
    expect(v.encoding).to eq(Encoding::UTF_8)
  end
end

RSpec.describe "Document.parse input retention" do
  # the C document BORROWS its input (zero-copy string views); the
  # wrapper must retain it or a GC frees memory every later node read
  # still points into (audit 2026-10-31). A heap-built string with no
  # other references, parse, GC, then read — the standard pin for the
  # GC-timing class (#182/#259 precedents).
  it "keeps node values readable across GC cycles" do
    key = "k" * 40
    val = "v" * 40
    doc = Yeptris::Document.parse(key + ": " + val + "\n")
    3.times { GC.start }
    root = doc.root(0)
    expect(root.keys.first.value).to eq(key)
    got = root[key]
    expect(got.value).to eq(val)
    3.times { GC.start }
    expect(got.value).to eq(val)
    doc&.free
  end

  it "parse_json retains its input the same way" do
    doc = Yeptris::Document.parse_json('{"' + ("j" * 40) + '": "' + ("w" * 40) + '"}')
    3.times { GC.start }
    root = doc.root(0)
    expect(root.keys.first.value).to eq("j" * 40)
    got = root["j" * 40]
    expect(got.value).to eq("w" * 40)
    doc&.free
  end
end
