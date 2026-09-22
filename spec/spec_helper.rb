# frozen_string_literal: true

# Standalone-repo defaults, in order: explicit override, a vendored
# platform copy, or the sibling C checkout's build (in-tree
# development before the platform gems exist)
lib = ENV["YEPTRIS_LIB_PATH"] ||
      Dir[File.expand_path("../lib/platform/*/libyeptris.*", __dir__)].first
if lib.nil?
  sibling = File.expand_path("../../yeptris/build-validate/src/libyeptris.dylib", __dir__)
  lib = sibling if File.exist?(sibling)
end
ENV["YEPTRIS_LIB_PATH"] = lib unless lib.nil?

require "yeptris"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
  config.order = :random

  # Per-example wall cap (#201): one pathological example on a noisy
  # shared runner once held a Spec leg hostage for 62 of its 65
  # minutes. 120s is far above the suite's p99 (the whole suite runs
  # in ~90s on ubuntu) and far below the leg's CI budget. The offender
  # FAILS with its name instead of eating the hour. Opt out per
  # example with metadata timeout: nil; tune with SLOW_SPEC_SECONDS.
  require "timeout"
  cap = (ENV["SLOW_SPEC_SECONDS"] || 120).to_f
  config.around(:each) do |example|
    if example.metadata[:timeout] == false
      example.run
      next
    end
    begin
      Timeout.timeout(cap) do
        example.run
      end
    rescue Timeout::Error
      # raising here fails THIS example with its name attached — a
      # pathological example can never eat the leg again. Caveat: a
      # pure-C FFI call is only interruptible at its return.
      raise "exceeded the #{cap.to_i}s per-example cap (#201) — " \
            "a real hang, or the example needs a SLOW_SPEC_SECONDS bump"
    end
  end
end
