# frozen_string_literal: true

require "spec_helper"
require "date"
require "set"

# The node-free dump lane (#857): YAMLTree rides the bulk build (one
# yeptris_document_build call, zero per-value node handles) whenever
# the graph is plain data with no anchor candidates. THE LAW: the lane
# switch is invisible — every dumped byte must equal the node walk's.
# force_node: true forces the old walk in-process, so the differential
# compares the two lanes over one corpus with no self-referential gap.
RSpec.describe "the node-free dump lane (#857)" do
  let(:visitor) { ->(obj, **kw) { ::Yeptris::Psych::Visitors::YAMLTree.new(**kw).push(obj).finish } }

  # plain-data corpus: every scalar type, every quoting shape the
  # visit_String matrix produces, keys of every arm (nil, chevron,
  # symbol, string, number), timestamps, binaries, multiline literals
  shared_hash = { "b" => "c" }
  let(:corpus) do
    [
      nil, true, false, 42, -17, 2**70, 3.25, 1.0e-7,
      Float::INFINITY, -Float::INFINITY, Float::NAN,
      "hello world", "", "null", "yes", "y", "N", "~", "on", "off",
      "123", "1.5", "07", "0189", "07:00:00", "2020-01-02",
      "a: b", "a #b", "- x", "-", "?", "abc:", "'x", 'say "hi"',
      "line1\nline2\nline3", "one\n", "a\tb", "ab", "héllo wörld",
      :symbol, :"a:b", :"",
      Time.utc(2020, 1, 2, 3, 4, 5), Time.new(2020, 1, 2, 3, 4, 5, "+09:00"),
      Date.new(2020, 1, 2),
      {}, [],
      { "a" => [1, 2, { "b" => "c" }], "d" => { "e" => nil } },
      { a: 1, b: [2, 3] },
      { 1 => "x", 2.5 => "y", true => "z" },
      { nil => "v" },
      { "k" => nil },
      { "<<" => { "b" => 2 }, "a" => 1 },
      [[1, [2, [3, [4]]]]],
      { "list" => [1, "two", :three, 4.0, nil, true], "map" => { "n" => 5 } },
      { "bin" => "\xFF\xFEabc".b },
      { "plain ascii".b => 1 },
      { "\xFF\xFEab".b => 1 },
      { "s" => "x" * 300 },
      (1..40).to_h { |i| ["key#{i}", i] },
      shared_hash, # a hash VALUE that is a shared plain scalar holder
    ].freeze
  end

  it "dumps byte-identically to the node walk across the corpus" do
    corpus.each do |obj|
      bulk = visitor.call(obj)
      node = visitor.call(obj, force_node: true)
      expect(bulk).to eq(node)
    end
  end

  it "matches the node walk under canonical and width options" do
    wide = (1..40).to_h { |i| ["key#{i}", "text #{i} " * 3] }
    [{ line_width: -1 }, { line_width: 20 }, { canonical: true },
     { line_width: 40, canonical: true }].each do |opts|
      [wide, corpus[24], corpus[30]].each do |obj|
        expect(visitor.call(obj, options: opts))
          .to eq(visitor.call(obj, force_node: true, options: opts))
      end
    end
  end

  it "takes the fast lane for plain graphs" do
    v = ::Yeptris::Psych::Visitors::YAMLTree.new
    v.push("a" => [1, 2, "three"])
    expect(v.fast_lane?).to be(true)
  end

  it "keeps the node lane when an anchorable object repeats" do
    shared = { "x" => 1 }
    v = ::Yeptris::Psych::Visitors::YAMLTree.new
    v.push("p" => shared, "q" => shared)
    expect(v.fast_lane?).to be(false)
    expect(v.finish).to include("&1")
    # the two lanes agree even here: both took the node walk
    expect(v.finish).to eq(visitor.call({ "p" => shared, "q" => shared }, force_node: true))
  end

  it "stays fast for shared strings, numbers and bools (no anchors)" do
    s = "shared"
    graph = { "p" => s, "q" => s, "n" => { 1 => 1 }, "b" => { true => true } }
    v = ::Yeptris::Psych::Visitors::YAMLTree.new
    v.push(graph)
    expect(v.fast_lane?).to be(true)
    expect(v.finish).not_to include("&")
    expect(v.finish).to eq(visitor.call(graph, force_node: true))
  end

  it "keeps the node lane for tagged and object shapes" do
    expect(visitor.call(DateTime.new(2020, 1, 2, 3, 4, 5, "+09:00"))).to(
      eq(visitor.call(DateTime.new(2020, 1, 2, 3, 4, 5, "+09:00"), force_node: true))
    )
    expect(visitor.call({ "t" => DateTime.new(2020, 1, 2, 3, 4, 5, "+09:00") })).to(
      include("!ruby/object:DateTime")
    )
    [Struct.new(:a, :b).new(1, 2), Set.new([1, 2]), Object.new].each do |obj|
      expect(visitor.call(obj)).to eq(visitor.call(obj, force_node: true))
    end
    # the same DumpError contract rides both lanes (a Numeric outside
    # the bulk set — Rational — keeps the visitor's refuse_dump form)
    expect { visitor.call(Rational(3, 2)) }.to raise_error(::Yeptris::DumpError)
    expect { visitor.call(Rational(3, 2), force_node: true) }
      .to raise_error(::Yeptris::DumpError, /include Yeptris::Psych::Encodable/)
  end

  it "keeps the node lane when the engine predates the bulk build" do
    stub_const("Yeptris::FFI::BULK_BUILD", false)
    v = ::Yeptris::Psych::Visitors::YAMLTree.new
    v.push("a" => [1, 2])
    expect(v.fast_lane?).to be(false)
    expect(v.finish).to eq(visitor.call({ "a" => [1, 2] }, force_node: true))
  end

  # The CBOR face consumes YAMLTree.document (the same tree the bulk
  # lane builds into). Byte parity there rides the DOM equivalence the
  # examples above pin — the same kinds/styles/tags — and the suite's
  # cbor_dump_marshal_spec re-verifies the wire contract end to end.
  it "hands the CBOR face an equivalent document (root kind + count)" do
    plain = { "a" => [1, 2.5, true, nil], "b" => "text" }
    fast_doc = ::Yeptris::Psych::Visitors::YAMLTree.new(schema: :compat_11)
    fast_doc.push(plain)
    node_doc = ::Yeptris::Psych::Visitors::YAMLTree.new(schema: :compat_11, force_node: true)
    node_doc.push(plain)
    fast_root = fast_doc.document.root(0)
    node_root = node_doc.document.root(0)
    expect(fast_root.kind).to eq(node_root.kind)
    expect(fast_root.size).to eq(node_root.size)
    expect(fast_root.to_ruby).to eq(node_root.to_ruby)
    fast_doc.document.free
    node_doc.document.free
  end
end
