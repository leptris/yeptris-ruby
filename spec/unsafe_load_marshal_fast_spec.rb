# frozen_string_literal: true

require "spec_helper"
require "date"
require "benchmark"

# #178: Psych.unsafe_load's marshal fast path — one C call materializes
# plain-data documents (Marshal.load builds the objects in C), replacing
# the per-node Nodes::Builder walk for exactly the documents it can
# express. These specs pin BOTH paths: the fast result is identical to
# the visitor's, and every construct the format cannot express (tags,
# timestamps, merge keys) falls back and revives correctly.
RSpec.describe "Psych.unsafe_load marshal fast path" do
  before(:all) { require "yeptris/psych/drop_in" }

  def walk_result(yaml)
    tree = Yeptris::Psych.parse(yaml)
    tree && Yeptris::Psych::Visitors::ToRuby.visit(tree.children.first)
  end

  PLAIN_DOCS = [
    "- :id: 1\n  file: x\n- :id: 2\n  file: y\n",
    "a: 1\nb: [two, 3.5]\nc: {d: true, e: null}\n",
    "utf8: héllo wörld\nsym: :name\n",
    "a: &x [1, 2]\nb: *x\n",
    "deep:\n  - - nested\n    - [flow, seq]\n",
    "just a scalar\n",
    "123\n",
  ].freeze

  describe "plain data (the fast payload)" do
    it "is identical to the visitor walk, document by document" do
      PLAIN_DOCS.each do |yaml|
        expect(::Psych.unsafe_load(yaml)).to eq(walk_result(yaml))
      end
    end

    it "preserves symbol keys and string encodings" do
      rows = ::Psych.unsafe_load("- :id: 1\n  :title: héllo\n")
      expect(rows[0].keys).to eq(%i[id title])
      expect(rows[0][:title]).to eq("héllo")
      expect(rows[0][:title].encoding).to eq(Encoding::UTF_8)
    end

    it "preserves alias identity within the document" do
      doc = ::Psych.unsafe_load("a: &x [1, 2]\nb: *x\n")
      expect(doc[:b]).to equal(doc[:a])
    end

    it "returns nil for an empty stream" do
      expect(::Psych.unsafe_load("")).to be_nil
      expect(::Psych.unsafe_load("# only a comment\n")).to be_nil
    end

    it "raises SyntaxError on malformed input like the walk" do
      expect { ::Psych.unsafe_load("a: [unclosed\n") }
        .to raise_error(Psych::SyntaxError)
    end
  end

  describe "constructs the format cannot express (the fallback)" do
    it "applies a domain type through the walk" do
      ::Yeptris::Psych.add_domain_type("mygem", "shout") do |_tag, val|
        val.is_a?(::Hash) ? val.transform_values { |v| v.to_s.upcase } : val
      end
      begin
        loaded = ::Psych.unsafe_load("--- !mygem:shout\nword: hello\n")
        expect(loaded).to eq("word" => "HELLO")
      ensure
        ::Yeptris::Psych.domain_types.clear
      end
    end

    it "revives tagged structs through the walk" do
      loaded = ::Psych.unsafe_load("--- !ruby/struct\nx: 3\ny: 4\n")
      expect(loaded).to be_a(Struct)
      expect([loaded.x, loaded.y]).to eq([3, 4])
    end

    it "materializes timestamps as Date objects" do
      loaded = ::Psych.unsafe_load("published: 2026-09-21\n")
      expect(loaded["published"]).to be_a(::Date)
    end

    it "expands merge keys" do
      loaded = ::Psych.unsafe_load("base: &b {x: 1, y: 2}\nsub:\n  <<: *b\n  y: 3\n")
      expect(loaded["sub"]).to eq("x" => 1, "y" => 3)
    end

    it "honors an explicit !!str tag" do
      loaded = ::Psych.unsafe_load("a: !!str 42\n")
      expect(loaded["a"]).to eq("42")
    end
  end

  describe "at scale (the #168/#178 workload)" do
    it "loads a 20k-row index in well under the walk's cost" do
      yaml = (1..20_000).map { |i| "- :id: #{i}\n  :file: f-#{i}\n" }.join
      rows = nil
      elapsed = ::Benchmark.realtime { rows = ::Psych.unsafe_load(yaml) }
      expect(rows.size).to eq(20_000)
      expect(rows[19_999][:file]).to eq("f-20000")
      # the fast path lands ~0.2s; the per-node walk ~2.5s on this
      # shape — 2s separates them beyond CI noise. A tripwire, not a
      # benchmark: the perf ledger's CI referee owns the numbers.
      expect(elapsed).to be < 2.0
    end
  end
end
