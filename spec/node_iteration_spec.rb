# frozen_string_literal: true

require "spec_helper"
require "benchmark"

# #168: the per-index iteration walks (seq_at/map_at in a loop) are
# O(i) sibling hops each — the 11 MB relaton ISO index (80k top-level
# rows) parsed in 238-328 s where stdlib takes ~3 s. #each/#each_pair
# now ride yeptris_node_children (one bulk walk); engines without it
# keep the per-index fallback. These specs pin both paths: order,
# completeness, pair interleaving, handle identity, and the scaled
# repro shape.
RSpec.describe Yeptris::Node, "#each / #each_pair (children drain)" do
  def with_doc(yaml)
    d = Yeptris::Document.parse(yaml)
    yield d.root
  ensure
    d&.free
  end

  it "yields every sequence element in order" do
    with_doc("- one\n- 2\n- [nested]\n- k: v\n") do |root|
      values = []
      root.each { |n| values << (n.sequence? || n.mapping? ? nil : n.to_ruby) }
      expect(values).to eq(["one", 2, nil, nil])
    end
  end

  it "yields nothing for an empty sequence" do
    with_doc("[]\n") do |root|
      expect(root.each.to_a).to eq([])
    end
  end

  it "yields ordered key,value pairs" do
    with_doc("a: 1\nb: two\nc: [x]\n") do |root|
      pairs = root.each_pair.to_a
      expect(pairs.map(&:first).map(&:to_ruby)).to eq(%w[a b c])
      expect(pairs.map(&:last).map(&:to_ruby)).to eq([1, "two", ["x"]])
      expect(root.keys.map(&:to_ruby)).to eq(%w[a b c])
    end
  end

  it "caches node identity across iterations" do
    with_doc("- a\n- b\n") do |root|
      first = root.each.to_a
      second = root.each.to_a
      expect(second.first.equal?(first.first)).to be(true)
    end
  end

  # The repro shape, scaled to keep CI honest: 50k single-key mapping
  # rows. The drain iterates in ~50 ms; the quadratic fallback pays
  # ~1.25e9 sibling hops and lands far outside the bound. The bound
  # carries a 30x margin over the drain — a wall-time spec only as a
  # regression tripwire, not a benchmark (perf claims live in the C
  # referee, per the ledger law).
  # Skipped on engines without the drain: the fallback is quadratic by
  # definition (the bug being fixed) — a 50k-row run would hang for
  # minutes, not fail usefully. The gem vendors the engine in lockstep,
  # so released gems always take the drain branch.
  it "iterates a 50k-row sequence in linear time",
     if: Yeptris::FFI::CHILDREN_DRAIN do
    yaml = (1..50_000).map { |i| "- n: #{i}\n" }.join
    doc = Yeptris::Document.parse(yaml)
    begin
      sum = 0
      elapsed = Benchmark.realtime do
        doc.root.each { |row| sum += row["n"].to_ruby }
      end
      expect(sum).to eq((50_000 * 50_001) / 2)
      expect(elapsed).to be < 5.0
    ensure
      doc.free
    end
  end
end
