# frozen_string_literal: true

# The CBOR referee (#157): interleaved A/B against the cbor gem on
# CI-fresh runners — dev-host isolated numbers are thermal fiction
# (the 2026-09-19 (ii) ledger entry); this is the honest venue.
#
#   bundle exec ruby benchmark/cbor_profile.rb [iterations]
#
# Fixtures mirror serialbench's canonical shapes: small (103B),
# medium (~141KB), large (~1.8MB), RFC 8949 canonical encodings,
# identical bytes for both sides.

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "benchmark"
require "yeptris"
require "yeptris/cbor"
require "cbor"

N = (ARGV[0] || 200).to_i

def small_doc
  {"id" => 42, "name" => "canonical", "tags" => %w[a b c], "ok" => true, "note" => nil}
end

def medium_doc
  {"users" => (1..200).map do |i|
    {"id" => i, "name" => "user#{i}", "email" => "u#{i}@example.com",
     "profile" => {"age" => i, "preferences" => {"theme" => "dark", "locale" => "en"}}}
  end}
end

def large_doc
  {"users" => (1..1000).map do |i|
    {"id" => i, "name" => "user #{i}", "email" => "user#{i}@example.com",
     "active" => i.even?, "score" => i * 0.5,
     "profile" => {"age" => i, "joined" => "2024-01-#{(i % 28) + 1}",
                   "preferences" => {"theme" => %w[dark light][i % 2], "locale" => "en"}}}
  end}
end

def run_fixture(name, doc)
  # serialbench's discipline: RFC 8949 canonical bytes, IDENTICAL for
  # both sides (the cbor gem's own encode is not canonical — comparing
  # decoders on different bytes measures encoders)
  bin = Yeptris::CBOR.dump(doc)

  n = name == :small ? N * 20 : (name == :medium ? N : N / 10)
  ours = theirs = 0.0
  ours_ips = theirs_ips = 0.0
  n.times do
    t1 = Benchmark.realtime { Yeptris::CBOR.load(bin) }
    t2 = Benchmark.realtime { CBOR.decode(bin) }
    ours += t1
    theirs += t2
  end
  ours_ips = n / ours
  theirs_ips = n / theirs
  puts format("| %<s>-7s | %<os>8.4f s | %<oi>10.0f ips | %<ts>8.4f s | %<ti>10.0f ips | cbor gem x%<r>.2f |",
              s: name, os: ours, oi: ours_ips, ts: theirs, ti: theirs_ips, r: theirs_ips / ours_ips)
end

puts
puts "CBOR.load vs the cbor gem (interleaved, #{N} base iterations, #{RUBY_DESCRIPTION})"
puts
puts "| fixture | yeptris total | yeptris ips | cbor gem total | cbor gem ips | ratio |"
puts "|---------|---------------|-------------|----------------|--------------|-------|"
run_fixture(:small, small_doc)
run_fixture(:medium, medium_doc)
run_fixture(:large, large_doc)
puts
puts "engine: #{defined?(Yeptris::Native) ? "native materializer" : "FFI ladder"}"
