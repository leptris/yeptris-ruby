# frozen_string_literal: true

require "spec_helper"
require "benchmark"

# #179b: asymptotic tripwires — every load path must stay LINEAR in
# document size. Wall-clock absolutes are fiction on shared CI runners
# (the ledger law); RATIOS are robust: time(2n) < 3·time(n) holds for
# a linear path with huge margin, fails catastrophically for a
# quadratic one (the #168 cliff was 20k→40k = 32×). This layer would
# have caught the cliff before any user did.
RSpec.describe "scale guards (asymptotic tripwires)" do
  before(:all) { require "yeptris/psych/drop_in" }

  def rows_doc(n)
    (1..n).map { |i| "- :id: #{i}\n  :file: f-#{i}\n  :title: t #{i}\n" }.join
  end

  def time_leg(path, doc)
    # GC before each leg: the ladder allocates per node, so heap state
    # from the previous leg would otherwise inflate the ratio
    ::GC.start
    ::Benchmark.realtime { path.call(doc) }
  end

  def ratio(path)
    small = rows_doc(5_000)
    large = rows_doc(10_000)
    # best-of-3 per leg: shared-runner spikes are single-shot; a
    # genuine asymptotic problem reproduces every round
    t_small = 3.times.map { time_leg(path, small) }.min
    t_large = 3.times.map { time_leg(path, large) }.min
    t_large / [t_small, 0.001].max
  end

  PATHS = {
    "unsafe_load (the marshal fast path)" => ->(y) { ::Psych.unsafe_load(y) },
    "safe_load (the ladder)" => ->(y) { ::Psych.safe_load(y, aliases: true) },
    "Document#to_ruby" => ->(y) {
      d = ::Yeptris::Document.parse(y, schema: :compat_11)
      begin
        d.root.to_ruby
      ensure
        d.free
      end
    },
    "Node#each (the drain)" => ->(y) {
      d = ::Yeptris::Document.parse(y, schema: :compat_11)
      begin
        n = 0
        d.root.each { n += 1 }
        n
      ensure
        d.free
      end
    }
  }.freeze

  # the bound sits between linear-with-GC (~2-3x per doubling) and
  # quadratic (4x per doubling: the #168 cliff measured 32x) — 3.5
  # discriminates with margin on both sides
  PATHS.each do |name, path|
    it "#{name}: 2x the document costs < 3.5x the time" do
      expect(ratio(path)).to be < 3.5
    end
  end
end
