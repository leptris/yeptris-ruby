# frozen_string_literal: true

# The consumer-pipeline benchmark leg (issue #69): a nested document
# walked into typed Ruby objects — the Amdahl shape where engine-level
# wins must show up end-to-end. Measures steady-state i/s with GC.stat
# allocation counters, plus fresh-process one-shot medians (CLI
# consumers parse each document once; YJIT measured ~2x PENALTY there
# on the consumer side, so cold shapes matter).
#
#   ruby benchmark/model_pipeline.rb             # steady-state + allocs
#   ruby benchmark/model_pipeline.rb --one-shot  # fresh-process medians

lib = ENV["YEPTRIS_LIB_PATH"] ||
      Dir[File.expand_path("../lib/platform/*/libyeptris.*", __dir__)].first
if lib.nil?
  sibling = File.expand_path("../../yeptris/build-shared/src/libyeptris.dylib", __dir__)
  lib = sibling if File.exist?(sibling)
end
ENV["YEPTRIS_LIB_PATH"] = lib unless lib.nil?
require "yeptris"
require "psych"

Model = Struct.new(:id, :name, :score, :active, :tags, :meta)
Meta = Struct.new(:origin, :weight)

BENCH_DOC = (+"").tap do |doc|
  5000.times do |i|
    doc << "item#{i}:\n  id: #{i}\n  name: alpha beta#{i % 97}\n  score: #{i}.5\n" \
           "  active: #{i.even?}\n  tags:\n    - alpha#{i % 7}\n    - beta#{i % 11}\n"
    doc << "  meta:\n    origin: gamma#{i % 13}\n    weight: #{i % 50}\n" if (i % 3).zero?
  end
end

def materialize(hash)
  hash.map do |_key, value|
    meta = value["meta"] && Meta.new(value["meta"]["origin"], value["meta"]["weight"])
    Model.new(value["id"], value["name"], value["score"], value["active"], value["tags"], meta)
  end
end

def run_steady(name, seconds: 2.0)
  load_fn = name == "yeptris" ? ->(s) { Yeptris::YAML.load(s) } : ->(s) { Psych.unsafe_load(s) }
  materialize(load_fn.call(BENCH_DOC)) # warm + probe
  GC.start
  allocs0 = GC.stat(:total_allocated_objects)
  iters = 0
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0 < seconds
    materialize(load_fn.call(BENCH_DOC))
    iters += 1
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  allocs = GC.stat(:total_allocated_objects) - allocs0
  format("%-9s steady %8.1f i/s   %6d allocs/doc", name, iters / elapsed, allocs / iters)
end

ONE_SHOT_PROBE = <<~RUBY
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  doc = %s
  materialize(doc)
  puts Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
RUBY

def run_one_shot(name, runs: 9)
  require_line = name == "yeptris" ? 'require "yeptris"' : 'require "psych"'
  loader = name == "yeptris" ? "Yeptris::YAML.load(BENCH_DOC)" : "Psych.unsafe_load(BENCH_DOC)"
  script = <<~RUBY
    #{require_line}
    #{format(ONE_SHOT_PROBE, loader)}
  RUBY
  times = runs.times.map do
    env = { "YEPTRIS_LIB_PATH" => ENV["YEPTRIS_LIB_PATH"].to_s }
    child = "ARGV << '-l'; load #{File.expand_path(__FILE__).inspect}; " + script
    IO.popen(env, [Gem.ruby, "-I", File.expand_path("../lib", __dir__), "-e", child], &:read)
      .to_f
  end.sort
  format("%-9s one-shot median %6.2f ms", name, times[times.size / 2] * 1000)
end

if $PROGRAM_NAME == __FILE__ && ARGV.none? { |a| a.start_with?("-l") }
  one_shot = ARGV.delete("--one-shot")
  %w[yeptris psych].each do |name|
    puts(one_shot ? run_one_shot(name) : run_steady(name))
  end
end
