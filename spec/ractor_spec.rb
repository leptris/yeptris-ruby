# frozen_string_literal: true

require "yeptris"
require "timeout"

# Ractor support (the C core's concurrency contract: one document per
# thread; read-only sharing safe — the parse path is per-call state on
# the native side and per-Ractor state on the Ruby side). The parse
# path must be pre-warmed on the main Ractor before spawning (the
# require does it: FFI attaches and the autoloads resolve there —
# require/autoload cannot run inside a non-main Ractor).
# Ruby 3.0's Ractor VM aborts the whole process mid-suite (core dump,
# nondeterministic) — the pin gates to 3.1+, where Ractor runs stable.
RACTOR_SUPPORTED = defined?(Ractor) && Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.1.0")

# Some ffi platform variants predate ffi 1.17's Ractor support and
# raise "defined with an un-shareable Proc in a different Ractor" on
# the first FFI call inside a non-main Ractor (observed: the
# windows-arm ffi variant). Probe for it once; skip with the reason
# instead of failing — the pin stays enforcing everywhere the
# runtime's ffi actually supports Ractors.
# The probe itself spawns a Ractor — it must NOT run on the 3.0 VM
# (it would crash the process the gate exists to protect).
RACTOR_FFI_CAPABLE = if RACTOR_SUPPORTED
  begin
    probe = Ractor.new do
      begin
        Yeptris::FFI.yeptris_version.to_s
        true
      rescue RuntimeError
        false
      end
    end
    probe.take
  rescue StandardError
    false
  end
else
  false
end

RSpec.describe "Ractor" do
  before do
    skip "Ractor aborts the 3.0 VM (core dump); 3.1+ runs it stable" unless RACTOR_SUPPORTED
    skip "this ffi platform variant lacks Ractor support (un-shareable Proc; ffi >= 1.17 provides it)" unless RACTOR_FFI_CAPABLE
  end

  # The windows VM intermittently wedges `take` — the #264/#504 class.
  # Round 1 of #285 parked the cross-talk example for the full raised
  # 360s cap; the #286 windows run then wedged a DIFFERENT example
  # ("produces shareable results", 120s) — the wedge hits arbitrary
  # takes, not one burst. Bound every take at 60s: on windows an
  # expiry becomes a LOUD skip (data for the #504 observational
  # ledger); everywhere else it stays a hard failure.
  def take_bounded(ractor)
    Timeout.timeout(60) { ractor.take }
  rescue Timeout::Error
    if RUBY_PLATFORM =~ /mingw|mswin/
      skip "ractor take wedged on #{RUBY_PLATFORM} (the #264/#504 class)"
    else
      raise
    end
  end

  it "parses inside a non-main Ractor" do
    r = Ractor.new do
      Yeptris::YAML.load("a: 1\nb: [x, y]\nc: {d: true}")
    end
    expect(take_bounded(r)).to eq("a" => 1, "b" => %w[x y], "c" => { "d" => true })
  end

  it "returns identical results across many parallel Ractors" do
    yaml = "defaults: &d\n  a: 1\n  b: 2\nitem:\n  <<: *d\n  x: y\n"
    expected = Yeptris::YAML.load(yaml)
    rs = 4.times.map do
      Ractor.new(yaml) { |y| d = nil; 3.times { d = Yeptris::YAML.load(y) }; d }
    end
    results = rs.map { |r| take_bounded(r) }.compact
    expect(results).to all(eq(expected))
  end

  it "produces shareable results" do
    s = Ractor.make_shareable(Yeptris::YAML.load("a: [1, {b: c}]"))
    expect(Ractor.shareable?(s)).to be(true)
    r = Ractor.new(s) { |shared| shared["a"].first + 1 }
    expect(take_bounded(r)).to eq(2)
  end

  it "parses distinct inputs in parallel without cross-talk" do
    rs = 6.times.map do |i|
      Ractor.new(i) { |n| Yeptris::YAML.load("k: v#{n}\nl: [#{n}, #{n + 1}]") }
    end
    results = rs.map { |r| take_bounded(r) }.compact
    expect(results).to eq(
      6.times.map { |n| { "k" => "v#{n}", "l" => [n, n + 1] } }
    )
  end
end
