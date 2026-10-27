# frozen_string_literal: true

require "yaml"

# Time-only scalars (yeptris#476): "07:00:00" and friends must load
# EXACTLY like Psych on the compat surface — a sexagesimal Integer of
# the clock in seconds when plain (Psych's own arithmetic: H:MM and
# H:MM:SS are hour-anchored, "1:30" is 5400, not positional base-60's
# 90), the untouched String when quoted, and a Time only for the full
# yaml.org timestamp production. A fixed-date-midnight value must
# never appear — the clock is the value.

RSpec.describe "time-only scalar parity with Psych (compat_11)" do
  PLAIN_CLOCKS = [
    "07:00:00",
    "07:00",
    "1:30",
    "1:2:3",
    "0:59",
    "23:59:59",
    "24:00:00",
    "-07:00:00",
    "07:00:00.5",
  ].freeze

  FULL_TIMESTAMPS = [
    "2001-12-14 21:59:43.10 -5",
    "2001-12-14t21:59:43.10-05:00",
    "2002-12-14",
  ].freeze

  def load_pair(scalar)
    yep = Yeptris::YAML.load("t: #{scalar}\n", schema: :compat_11)["t"]
    psy = Psych.unsafe_load("t: #{scalar}\n")["t"]
    [yep, psy]
  end

  it "plain time-only scalars are Psych's sexagesimal seconds" do
    PLAIN_CLOCKS.each do |clock|
      yep, psy = load_pair(clock)
      expect(yep).to eq(psy), "#{clock}: yeptris gave #{yep.inspect}, psych gives #{psy.inspect}"
      expect(yep.class).to eq(psy.class), "#{clock}: #{yep.class} vs psych's #{psy.class}"
    end
  end

  it "quoted time-only scalars stay strings" do
    PLAIN_CLOCKS.each do |clock|
      yep, psy = load_pair(%("#{clock}"))
      expect(yep).to eq(psy)
      expect(yep).to eq(clock)
    end
  end

  it "full timestamps stay timestamps" do
    FULL_TIMESTAMPS.each do |stamp|
      yep, psy = load_pair(stamp)
      expect(yep).to eq(psy)
    end
  end
end
