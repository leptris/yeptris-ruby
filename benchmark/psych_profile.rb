# frozen_string_literal: true

# The Psych facade comparison profile (issue #862) — the drop-in is
# what Psych-based consumers actually exercise, so THIS is the surface
# the engine has to win on.
#
# Order-alternating interleaved A/B against stdlib Psych (the same
# discipline as json_profile.rb), on an #862-shaped corpus: a
# top-level hash of 6699 entries mapping style keys to arrays of
# strings (the fontist formula index). Covers safe_load (clean +
# gated), load, and dump, and prints the pipeline decomposition
# (clean marshal lane / recorder drain / records gate+build) plus the
# GATED fallback (a document with aliases and explicit tags) so a
# lane change is visible against both paths.
#
#   bundle exec ruby benchmark/psych_profile.rb [iterations] [entries]
#
# This process must NOT load yeptris/psych/drop_in — ::Psych must stay
# the stdlib gem for the A/B to mean anything.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "benchmark"
require "psych" # stdlib: loaded BEFORE yeptris/psych (namespace only, #69)
require "yeptris"
require "yeptris/psych"

raise "stdlib Psych was rebound" unless ::Psych.equal?(::Psych)

N = (ARGV[0] || 20).to_i
ENTRIES = (ARGV[1] || 6699).to_i

def clean_corpus(entries)
  lines = []
  entries.times do |i|
    lines << "#{i}-style-name-#{i % 97}:"
    lines << "  - family-#{i % 11} regular"
    lines << "  - family-#{i % 11} bold"
    lines << "  - family-#{i % 11} italic"
  end
  lines.join("\n") << "\n"
end

def gated_corpus(entries)
  # one alias, one explicit tag, one timestamp: the full permission
  # walk must run (marshal refuses timestamps; the gate bytes exist)
  body = clean_corpus(entries)
  <<~YAML
    #{body}anchor-one: &a value
    reuse: *a
    tagged: !!str text
    when: 2001-12-14
  YAML
end

CLEAN = clean_corpus(ENTRIES)
GATED = gated_corpus(ENTRIES)

# Parity first: the two faces must agree on the corpus result
raise "parity broken" unless
  ::Psych.safe_load(CLEAN) == Yeptris::Psych.safe_load(CLEAN)

def ab(label, a_block, b_block, n)
  times_a = []
  times_b = []
  n.times do |k|
    if k.even?
      times_a << Benchmark.realtime(&a_block)
      times_b << Benchmark.realtime(&b_block)
    else
      times_b << Benchmark.realtime(&b_block)
      times_a << Benchmark.realtime(&a_block)
    end
  end
  mean_a = times_a.sum / n
  mean_b = times_b.sum / n
  kb = label =~ /clean/ ? CLEAN.bytesize / 1024 : GATED.bytesize / 1024
  puts format("%-24s %8.2f ms  %8.2f ms  vs stdlib %.2fx  (%d KB)",
              label, mean_a * 1000, mean_b * 1000, mean_a / mean_b, kb)
  [mean_a, mean_b]
end

puts "corpus: #{CLEAN.bytesize / 1024} KB clean / #{GATED.bytesize / 1024} KB gated, N=#{N} (order-alternating), #{RUBY_PLATFORM}"

# Warm both engines
::Psych.safe_load(CLEAN)
Yeptris::Psych.safe_load(CLEAN)
GATED_OPTS = { aliases: true, permitted_classes: [::Date, ::Time] }.freeze
::Psych.safe_load(GATED, **GATED_OPTS)
Yeptris::Psych.safe_load(GATED, **GATED_OPTS)

raise "gated parity broken" unless
  ::Psych.safe_load(GATED, **GATED_OPTS) == Yeptris::Psych.safe_load(GATED, **GATED_OPTS)

puts
ab("safe_load clean", -> { ::Psych.safe_load(CLEAN) }, -> { Yeptris::Psych.safe_load(CLEAN) }, N)
ab("safe_load gated", -> { ::Psych.safe_load(GATED, **GATED_OPTS) },
   -> { Yeptris::Psych.safe_load(GATED, **GATED_OPTS) }, N)
ab("load clean", -> { ::Psych.load(CLEAN) }, -> { Yeptris::Psych.load(CLEAN) }, N)

# The #862 dump rows: stdlib's dump walks the object graph through the
# YAMLTree visitor (libyaml event emitter); the facade's plain-data
# lane is the BulkBuilder (one build_entries call + one serialize).
DATA = ::Psych.safe_load(CLEAN)
raise "dump parity broken" unless ::Psych.dump(DATA) == Yeptris::Psych.dump(DATA)

::Psych.dump(DATA)
Yeptris::Psych.dump(DATA)
puts
puts "== dump =="
ab("dump hash-of-seqs", -> { ::Psych.dump(DATA) }, -> { Yeptris::Psych.dump(DATA) }, N)
ab("dump stream-io", lambda {
                      io = StringIO.new
                      ::Psych.dump(DATA, io)
                    }, lambda {
                         io = StringIO.new
                         Yeptris::Psych.dump(DATA, io)
                       }, N)

# The pipeline decomposition (clean corpus): what each lane costs in
# isolation, so a change to any lane is attributable. The clean lane
# is ONE C call (marshal); the gated lane is the recorder drain + the
# record-array gate + the record stack machine.
times = Array.new(N) do
  Benchmark.realtime { ::Yeptris::ValueML.load_all_marshal(CLEAN, schema: :compat_11, mode: :all) }
end
puts format("  clean lane (marshal, one call)  %8.2f ms", times.sum / N * 1000)

times = Array.new(N) do
  Benchmark.realtime { ::Yeptris::Materializer.drain(CLEAN, schema: :compat_11) }
end
puts format("  recorder drain                  %8.2f ms", times.sum / N * 1000)

times = Array.new(N) do
  Benchmark.realtime do
    flat, arena = ::Yeptris::Materializer.drain(CLEAN, schema: :compat_11)
    begin
      ::Yeptris::Psych.send(:check_records, flat, arena, [::Date, ::Time], false)
    rescue ::Yeptris::Psych::DisallowedClass, ::Yeptris::Psych::AliasesError
      nil
    end
    ::Yeptris::Materializer.new.materialize_records(flat, arena)
  end
end
puts format("  gated lane (drain+gate+build)   %8.2f ms", times.sum / N * 1000)
