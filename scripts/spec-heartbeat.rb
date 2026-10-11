# spec-heartbeat.rb — #504: in-process evidence for the intermittent
# rspec hang. Required into the rspec process via -r. Every example
# transition touches a heartbeat; a watcher thread dumps all Ruby
# thread backtraces (and the example that was running) when no
# transition happens for STALL seconds, then re-arms — it never kills,
# because legitimate examples run longer than any threshold we could
# pick (the macos suite takes 32 minutes at full CPU). The outer
# spec-watchdog owns the kill decision via the CPU-growth rule. If
# these dumps never appear while the outer watchdog fires, the main
# thread is blocked inside C/FFI holding the GVL — that absence is
# itself the finding.
$stderr.sync = true
HEARTBEAT_STALL = Integer(ENV.fetch("SPEC_HEARTBEAT_STALL", "540"))
HEARTBEAT_STATE = {at: Time.now, what: "suite start", dumps: 0}
HEARTBEAT_MU = Mutex.new

def _heartbeat_mark(what)
  HEARTBEAT_MU.synchronize do
    HEARTBEAT_STATE[:at] = Time.now
    HEARTBEAT_STATE[:what] = what
  end
end

if defined?(RSpec)
  RSpec.configure do |config|
    config.around do |example|
      _heartbeat_mark(example.full_description)
      example.run
      _heartbeat_mark("#{example.full_description} (done)")
    end
  end
end

Thread.new do
  $stderr.puts "[heartbeat] watcher thread started"
  loop do
    sleep 10
    at, what, dumps = HEARTBEAT_MU.synchronize { [HEARTBEAT_STATE[:at], HEARTBEAT_STATE[:what], HEARTBEAT_STATE[:dumps]] }
    next unless Time.now - at > HEARTBEAT_STALL * (dumps + 1)
    HEARTBEAT_MU.synchronize { HEARTBEAT_STATE[:dumps] += 1 }
    $stderr.puts "\n[heartbeat ##{dumps + 1}] NO EXAMPLE TRANSITION FOR #{(Time.now - at).round}s — was running: #{what.inspect}"
    $stderr.puts "[heartbeat] all Ruby thread backtraces:"
    Thread.list.each do |t|
      $stderr.puts "--- #{t.inspect} ---"
      bt = t.backtrace
      $stderr.puts(bt ? bt.join("\n") : "<no backtrace — blocked in C/FFI or the VM>")
    end
    $stderr.puts "[heartbeat] dump-only; the outer watchdog decides the kill"
    $stderr.flush
  end
end
