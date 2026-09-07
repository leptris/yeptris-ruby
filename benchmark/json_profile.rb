# frozen_string_literal: true

# The JSON comparison profile — THE REFEREE (TODO.restructure/34/36).
#
# Order-alternating interleaved A/B (fixed order biases the second
# runner's cache), reporting min/median/mean, pair-ratio distribution,
# head-to-head. When the native engine is loaded, --all-modes A/Bs
# every GC strategy in-process (the CI table); a single run reports
# the configured mode.
#
#   bundle exec ruby benchmark/json_profile.rb [iterations] [corpus_items]
#
# GC mode comes from YEPTRIS_NATIVE_GC at LOAD time — modes must be
# compared in SEPARATE processes (an in-process switch changes the GC
# environment for both sides; measured contamination, not a valid A/B).

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

def measure(json, n)
  times_y = []
  times_j = []
  n.times do |k|
    if k.even?
      times_y << Benchmark.realtime { Yeptris::JSON.load(json) }
      times_j << Benchmark.realtime { JSON.parse(json) }
    else
      times_j << Benchmark.realtime { JSON.parse(json) }
      times_y << Benchmark.realtime { Yeptris::JSON.load(json) }
    end
  end
  mean_y = times_y.sum / n
  mean_j = times_j.sum / n
  ratios = times_y.zip(times_j).map { |y, j| y / j }.sort
  wins = times_y.zip(times_j).count { |y, j| y < j }
  [times_y.min, times_y.sort[n / 2], mean_y, times_j.min, times_j.sort[n / 2], mean_j,
   ratios[n / 10], ratios[n / 2], ratios[9 * n / 10], wins]
end

modes = if defined?(Yeptris::Native)
         [Yeptris::Native.gc_mode]
       else
         [:fallback]
       end

puts "corpus: #{json.bytesize / 1024} KB / ~#{ITEMS * 10} values, N=#{N} (order-alternating interleave), #{RUBY_PLATFORM}"
puts "engine: #{defined?(Yeptris::Native) ? 'native extension' : 'record-drain fallback'}"
if defined?(Yeptris::Native)
  puts "knobs: gc=#{Yeptris::Native.gc_mode} ins=#{Yeptris::Native.ins_mode} cache=#{Yeptris::Native.cache_mode} shape=#{Yeptris::Native.shape_mode}"
  # the decomposition (TODO.restructure/37): the pure grammar walk
  # (same scan kernels, null vtable) bounds the scan cost; the rest
  # of our time is materialization.
  printf("scan-only: %.3f ms/iter (grammar walk, no Ruby objects)\n",
         Yeptris::Native.scan_time(json, 50) * 1e3)
end
puts
puts format("%-10s %-28s %8s %8s %8s %10s %6s",
            "gc_mode", "", "min", "median", "mean", "vs json", "h2h")

warmup = [N, 30].min
warmup.times { Yeptris::JSON.load(json); JSON.parse(json) }

jsonp = nil
modes.each do |mode|
  Yeptris::Native.gc_mode = mode if defined?(Yeptris::Native) && mode != :fallback
  y_min, y_med, y_mean, j_min, j_med, j_mean, p10, p50, p90, wins = measure(json, N)
  jsonp ||= j_mean
  puts format("%-10s yeptris %-8s %7.3f %8.3f %8.3f %9.3fx %5d/%d",
              mode.to_s, "", y_min * 1e3, y_med * 1e3, y_mean * 1e3, y_mean / j_mean, wins, N)
  puts format("%-10s json   %-8s %7.3f %8.3f %8.3f   p10/p50/p90 %.2f/%.2f/%.2f",
              "", "", j_min * 1e3, j_med * 1e3, j_mean * 1e3, p10, p50, p90)
  gate = ENV["GATE"].to_s
  unless gate.empty?
    if (y_mean / j_mean) >= gate.to_f
      warn(format("GATE FAILED: mean ratio %.3fx >= %s", y_mean / j_mean, gate))
      exit 1
    end
  end
  # GC footprint per parser, attribution-clean (one parser per phase):
  # the page hypothesis (TODO.restructure/34) predicts the disable
  # mode grows heap pages where none recycles them.
  [:yeptris, :json].each do |side|
    fn = side == :yeptris ? -> { Yeptris::JSON.load(json) } : -> { JSON.parse(json) }
    GC.start
    before = GC.stat.slice(:heap_allocated_pages, :minor_gc_count, :major_gc_count)
    n2 = 50
    n2.times { fn.call }
    after = GC.stat.slice(:heap_allocated_pages, :minor_gc_count, :major_gc_count)
    d_pages = after[:heap_allocated_pages] - before[:heap_allocated_pages]
    d_minor = after[:minor_gc_count] - before[:minor_gc_count]
    d_major = after[:major_gc_count] - before[:major_gc_count]
    puts format("           %-7s gc-footprint(50 iters): pages %+d  minor %d  major %d",
                side, d_pages, d_minor, d_major)
  end
end
