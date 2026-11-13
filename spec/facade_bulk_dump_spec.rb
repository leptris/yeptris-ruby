# frozen_string_literal: true

# The #862 dump cut: plain-data graphs ride the BulkBuilder (ONE
# build_entries call + one serialize — the neutral surface's law set)
# instead of the YAMLTree visitor's per-node FFI DOM build. The pins
# below hold the fast lane BYTE-IDENTICAL to the visitor it replaces,
# and hold every refusal (shared/cyclic containers, Time/Date repeats,
# DateTime, Struct/Set/Encodable, custom objects) on the visitor,
# whose output is unchanged.
require "yeptris/psych"
require "psych"
require "stringio"
require "date"
require "set"

RSpec.describe "facade bulk dump lanes (#862)" do
  def visitor_dump(obj, options = {})
    ::Yeptris::Psych::Visitors::YAMLTree.new(options: options).push(obj).finish
  end

  {
    "plain hash of seqs" => { "alpha" => [1, 2, 3], "beta" => %w[x y z] },
    "nested containers" => [[[1, "a"], [2, "b"]], [], { "k" => { "deep" => [nil] } }],
    "symbols and floats" => { key1: 1.5, "e" => [2.0, :sym, true, false] },
    "reshape words quote" => { "n" => 1, "yes" => "quoted", "y" => "why" },
    "multiline literal" => { "m" => ["a\nb\nc"] },
    "binary string" => { "blob" => ["\xC3\xA9x".dup.force_encoding(Encoding::BINARY)] },
    "nil and chevron keys" => { nil => "nul", "<<" => "merge", 42 => "i", 1.5 => "f" },
    "timestamps" => { "d" => [::Date.new(2020, 1, 1), ::Time.at(0).utc] },
  }.each do |name, graph|
    it "matches the visitor byte for byte: #{name}" do
      fast = ::Yeptris::Psych.dump(graph)
      expect(fast).to eq(visitor_dump(graph))
      expect(fast).to end_with("\n")
    end
  end

  it "dumps stdlib-identically on the plain hash corpus" do
    graph = { "alpha" => [1, 2, 3], "n" => 1, "yes" => "q" }
    expect(::Yeptris::Psych.dump(graph)).to eq(::Psych.dump(graph))
  end

  it "writes to the io face and returns it" do
    io = StringIO.new
    out = ::Yeptris::Psych.dump({ "a" => [1] }, io)
    expect(out).to equal(io)
    expect(io.string).to eq(::Yeptris::Psych.dump({ "a" => [1] }))
  end

  it "honors line_width on the fast lane" do
    graph = { "k" => ["a value that is long enough to fold when the width is small"] }
    narrow = ::Yeptris::Psych.dump(graph, line_width: 20)
    wide = ::Yeptris::Psych.dump(graph, line_width: 1000)
    expect(narrow).to eq(visitor_dump(graph, line_width: 20))
    expect(narrow).not_to eq(wide)
  end

  it "keeps shared containers on the visitor (the &1/*1 anchor law)" do
    shared = { "deep" => [1] }
    graph = { "a" => shared, "b" => shared }
    out = ::Yeptris::Psych.dump(graph)
    expect(out).to eq(visitor_dump(graph))
    expect(out).to match(/&1/)
    expect(out).to match(/\*1/)
  end

  it "keeps cyclic graphs on the visitor" do
    cyc = { "self" => nil }
    cyc["self"] = cyc
    expect(::Yeptris::Psych.dump(cyc)).to eq(visitor_dump(cyc))
  end

  it "keeps repeated Time/Date objects on the visitor (test_alias_with_time)" do
    t = ::Time.at(0).utc
    out = ::Yeptris::Psych.dump({ a: t, b: t })
    expect(out).to match(/&/)
  end

  it "keeps DateTime on the visitor (the !ruby/object:DateTime tag)" do
    graph = { "when" => [::DateTime.new(2020, 1, 1, 12, 30, 45, "+09:00")] }
    out = ::Yeptris::Psych.dump(graph)
    expect(out).to eq(visitor_dump(graph))
    expect(out).to include("!ruby/object:DateTime")
  end

  it "keeps Set, Struct and bare objects on the visitor" do
    set_graph = { "s" => [::Set.new([1, 2])] }
    expect(::Yeptris::Psych.dump(set_graph)).to eq(visitor_dump(set_graph))
    st = Struct.new(:a, :b).new(1, 2)
    expect(::Yeptris::Psych.dump({ "st" => st })).to eq(visitor_dump({ "st" => st }))
  end

  it "refuses custom objects through either lane" do
    anon = Class.new.new # an anonymous-class instance: no Encodable, not a bare Object
    expect { ::Yeptris::Psych.dump({ "o" => anon }) }
      .to raise_error(::Yeptris::DumpError)
  end

  # The facade's bulk lane carries the chevron-key tag as the full
  # core URI — the engine's tag writer renders !!str from it; the
  # verbatim shorthand rides the URI escaper through the bulk build
  # (BulkBuilder::MERGE_KEY_TAG, shared with the visitor's #857 lane).
  it "emits the chevron key as !!str through the facade's bulk lane" do
    out = ::Yeptris::Psych.dump({ "<<" => "merge", "a" => 1 })
    expect(out).to include("!!str '<<'")
    expect(out).not_to include("%21")
    expect(out).to eq(visitor_dump({ "<<" => "merge", "a" => 1 }))
    # and it must re-load as a literal key, not a merge
    expect(::Yeptris::Psych.safe_load(out)).to eq("<<" => "merge", "a" => 1)
  end

  it "keeps the scalar-root fast lane identical under the merge_tag knob" do
    # the neutral default stays the shorthand (the #857 documented form)
    expect(::Yeptris::YAML.dump({ "<<" => "m" }))
      .to eq(::Yeptris::YAML.dump({ "<<" => "m" }, merge_tag: "!!str"))
  end
end
