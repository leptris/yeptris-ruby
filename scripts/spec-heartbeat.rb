# spec-heartbeat.rb — #504: in-process evidence for the intermittent
# rspec hang. Required into the rspec process via -r. Every example
# transition touches a heartbeat; a watcher thread dumps all Ruby
# thread backtraces (and the example that was running) when no
# transition happens for STALL seconds. If the dump never appears but
# the outer watchdog fires, the main thread is blocked inside C/FFI
# holding the GVL — itself a finding.
$stderr.sync = true
HEARTBEAT_STALL = Integer(ENV.fetch("SPEC_HEARTBEAT_STALL", "540"))
HEARTBEAT_STATE = {at: Time.now, what: "suite start"}
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
  loop do
    sleep 10
    at, what = HEARTBEAT_MU.synchronize { [HEARTBEAT_STATE[:at], HEARTBEAT_STATE[:what]] }
    next unless Time.now - at > HEARTBEAT_STALL
    $stderr.puts "\n[heartbeat] NO EXAMPLE TRANSITION FOR #{HEARTBEAT_STALL}s — was running: #{what.inspect}"
    $stderr.puts "[heartbeat] all Ruby thread backtraces:"
    Thread.list.each do |t|
      $stderr.puts "--- #{t.inspect} ---"
      bt = t.backtrace
      $stderr.puts(bt ? bt.join("\n") : "<no backtrace — blocked in C/FFI or the VM>")
    end
    $stderr.puts "[heartbeat] if nothing follows this in the log, the GVL is held by the blocked call"
    $stderr.flush
    sleep 10
    exit! 7
  end
end
