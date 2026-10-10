# spec-watchdog.rb — #504: the intermittent windows hang (bundler +
# rspec context, no output until the 6h kill). Runs rspec as a child
# with progress output streaming. The kill rule is CPU growth, not
# output: the healthy macos suite runs 32 minutes with zero output at
# full CPU, so silence means nothing — a hang means the child's
# cumulative CPU stops growing (the caught windows hang sat at
# 0.015625s total, forever). spec-heartbeat.rb rides inside the child
# and dumps in-process thread backtraces; its absence from a killed
# run means the GVL was held inside C/FFI.
$stdout.sync = true
$stderr.sync = true
STALL = Integer(ENV.fetch("SPEC_WATCHDOG_STALL", "1800"))
CPU_WINDOW = Integer(ENV.fetch("SPEC_WATCHDOG_CPU_WINDOW", "180"))
CPU_FLOOR = Integer(ENV.fetch("SPEC_WATCHDOG_CPU_FLOOR", "1"))
require "open3"
last_line = nil
last_at = Time.now

# A stall is only a hang when the child also stops burning CPU: slow
# runners (arm) legitimately sit 10+ min between output lines at full
# tilt.  posix: ps -o time; windows: Get-Process CPU.
def child_cpu(pid)
  if RUBY_PLATFORM =~ /mingw|mswin/
    return `powershell -Command "(Get-Process -Id #{pid} -ErrorAction SilentlyContinue).CPU"`.to_f
  end
  # cputime is [[dd-]hh:]mm:ss[.cc]; darwin's ps has no `times` keyword
  # and its error text coerced to 0 — a healthy run looked "stalled"
  out = `ps -o cputime= -p #{pid} 2>/dev/null`.strip
  return -1 if out.empty?
  parts = out.split(":").map { |seg| seg.to_f }
  parts.reverse.each_with_index.sum { |seg, i| seg * (60**i) }
rescue StandardError
  -1
end
thr = Thread.new do
  # rspec's progress dots block-buffer when stdout is a pipe (no tty) —
  # line-buffer the child so output actually streams to the watchdog
  hb = File.expand_path("#{__dir__}/spec-heartbeat.rb")
  cmd = RUBY_PLATFORM =~ /mingw|mswin/ ? ["bundle", "exec", "rspec", "--format", "progress", "-r", hb]
                                       : ["stdbuf", "-oL", "bundle", "exec", "rspec", "--format", "progress", "-r", hb]
  Open3.popen3(*cmd) do |i, o, e, w|
    @pid = w.pid
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
last_cpu = -1.0
last_cpu_at = Time.now
loop do
  break unless thr.alive?
  now = Time.now
  pid = @pid || -1
  cpu = child_cpu(pid)
  if cpu >= 0
    if cpu >= last_cpu + CPU_FLOOR
      last_cpu = cpu
      last_cpu_at = now
    elsif now - last_cpu_at > CPU_WINDOW && now - last_at > STALL
      cpu1 = child_cpu(pid)
      sleep 10
      cpu2 = child_cpu(pid)
      if cpu1 >= 0 && cpu2 < cpu1 + 2
        puts "\n[watchdog] CPU GREW #{(cpu1 - last_cpu).round(2)}s IN #{((now - last_cpu_at) / 60).round(1)}min (window #{CPU_WINDOW}s, floor #{CPU_FLOOR}s) AND NO OUTPUT FOR #{((now - last_at) / 60).round(1)}min — last line: #{last_line.inspect}"
        puts "[watchdog] NOTE: no [heartbeat] dump above means the child could not run Ruby code — blocked in C/FFI holding the GVL"
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
    end
  end
  sleep 5
end
thr.join
exit(@status ? @status.exitstatus : 0)
