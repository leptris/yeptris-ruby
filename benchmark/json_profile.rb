# frozen_string_literal: true

# The JSON comparison profile (TODO.restructure/31).
#
# The FAIR benchmark for the JSON.parse race: interleaved A/B so
# parse-order noise hits both sides equally; reports min/median/mean,
# the pair-ratio distribution, and head-to-head wins. Any
# steady-state claim — ours or a user's — must reproduce through
# this profile before it changes a default.
#
#   bundle exec ruby benchmark/json_profile.rb [iterations] [corpus_items]

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "benchmark"
require "json"
require "yeptris"

N = (ARGV[0] || 400).to_i
ITEMS = (ARGV[1] || 1400).to_i

json = (+"[").tap do |j|
  ITEMS.times do |i|
    j << %({"id":#{i},"name":"item #{i}","tags":["a","b",#{i}],"meta":{"v":#{i * 7},"ok":true,"note":"text #{i} for the corpus"}})
    j << "," unless i == ITEMS - 1
  end
end << "]"

raise "parity broken" unless Yeptris::JSON.load(json) == JSON.parse(json)

engine = defined?(Yeptris::Native) ? "native extension" : "record-drain fallback"
puts "corpus: #{json.bytesize / 1024} KB / ~#{ITEMS * 10} values, N=#{N} (interleaved), engine: #{engine}"

warmup = [N, 30].min
warmup.times { Yeptris::JSON.load(json); JSON.parse(json) }

times_y = []
times_j = []
N.times do |k|
  # alternate the order each iteration: whichever parser runs second
  # inherits cache warmth — a fixed order is a fixed bias
  if k.even?
    times_y << Benchmark.realtime { Yeptris::JSON.load(json) }
    times_j << Benchmark.realtime { JSON.parse(json) }
  else
    times_j << Benchmark.realtime { JSON.parse(json) }
    times_y << Benchmark.realtime { Yeptris::JSON.load(json) }
  end
end

mean_y = times_y.sum / N
mean_j = times_j.sum / N
ratios = times_y.zip(times_j).map { |y, j| y / j }.sort
wins = times_y.zip(times_j).count { |y, j| y < j }

printf("JSON.parse        min %.3f  med %.3f  mean %.3f ms\n",
       times_j.min * 1e3, times_j.sort[N / 2] * 1e3, mean_j * 1e3)
printf("Yeptris::JSON     min %.3f  med %.3f  mean %.3f ms\n",
       times_y.min * 1e3, times_y.sort[N / 2] * 1e3, mean_y * 1e3)
printf("mean ratio %.3fx (%s)  pair-ratio p10/p50/p90 %.2f/%.2f/%.2f  head-to-head %d/%d\n",
       mean_y / mean_j, mean_y < mean_j ? "FASTER" : "slower",
       ratios[N / 10], ratios[N / 2], ratios[9 * N / 10], wins, N)
