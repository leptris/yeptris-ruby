# spec-watchdog.rb — #504: the intermittent windows hang (bundler +
# rspec context, no output until the 6h kill). Runs rspec as a child
# with progress output streaming; on a stall dumps every Ruby thread's
# backtrace from OUTSIDE the hung process via a DRb-free trick: the
# child polls its own threads from a watcher thread until output
# stalls, then prints Thread.list backtraces to stderr and exits.
$stdout.sync = true
$stderr.sync = true
STALL = Integer(ENV.fetch("SPEC_WATCHDOG_STALL", "600"))
require "open3"
last_line = nil
last_at = Time.now
thr = Thread.new do
  # rspec's progress dots block-buffer when stdout is a pipe (no tty) —
  # line-buffer the child so output actually streams to the watchdog
  cmd = RUBY_PLATFORM =~ /mingw|mswin/ ? %w[bundle exec rspec --format progress]
                                       : %w[stdbuf -oL bundle exec rspec --format progress]
  Open3.popen3(*cmd) do |i, o, e, w|
    o.each_line do |line|
      print line
      last_line = line
      last_at = Time.now
    end
    err = Thread.new { e.each_line { |l| warn l } }
    err.join
    i.close
    @status = w.value
  end
end
loop do
  break unless thr.alive?
  if Time.now - last_at > STALL
    puts "\n[watchdog] NO OUTPUT FOR #{STALL}s — last line: #{last_line.inspect}"
    puts "[watchdog] ruby threads of THIS process (parent):"
    Thread.list.each do |t|
      puts "--- #{t} ---"
      puts (t.backtrace || ["<no backtrace>"]).join("\n")
    end
    puts "[watchdog] child process tree:"
    if RUBY_PLATFORM =~ /mingw|mswin/
      system("powershell -Command \"Get-CimInstance Win32_Process -Filter \\\"Name='ruby.exe'\\\" | Select-Object ProcessId,ParentProcessId,CommandLine | Format-List\"")
      system("powershell -Command \"Get-Process ruby -ErrorAction SilentlyContinue | ForEach-Object { $_.Threads | Select-Object Id,ThreadState,WaitReason } | Format-Table\"")
    else
      system("ps -ef | grep -E 'rspec|ruby' | grep -v grep")
    end
    puts "[watchdog] killing the child tree and failing"
    if RUBY_PLATFORM =~ /mingw|mswin/
      system("powershell -Command \"Stop-Process -Name ruby -Force -ErrorAction SilentlyContinue\"")
    end
    exit! 3
  end
  sleep 5
end
thr.join
exit(@status ? @status.exitstatus : 0)
