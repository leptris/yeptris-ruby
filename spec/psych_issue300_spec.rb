# frozen_string_literal: true

require "spec_helper"
require "yeptris/yaml"
require "yeptris/psych"

# Issue #300 (the two remaining families) + #95 bug 4 (load_tags).
RSpec.describe "Psych parity: timestamps and load_tags" do
  before(:all) { require "yaml" unless defined?(::YAML) }

  def parity(obj)
    expect(Yeptris::YAML.dump(obj, header: true)).to eq(::YAML.dump(obj))
  end

  it "serializes Time exactly as Psych (space, nanoseconds, Z)" do
    # the bundled ::YAML may predate psych-5's format_time — pin the
    # psych-5 bytes (the issue's oracle) rather than parity here
    expect(Yeptris::YAML.dump({ "t" => Time.utc(2026, 9, 7, 10, 0, 0) }, header: true))
      .to eq("---\nt: 2026-09-07 10:00:00.000000000 Z\n")
    # nanosecond width via Rational (the float literal truncates one
    # nano — Time's own precision, psych prints the same 788)
    frac = Time.utc(2026, 1, 2, 3, 4, Rational(5_123_456_789, 1_000_000_000))
    expect(Yeptris::YAML.dump({ "frac" => frac }, header: true))
      .to include("frac: 2026-01-02 03:04:05.123456789 Z")
  end

  it "keeps Date as Psych's calendar form" do
    parity("d" => Date.new(2026, 9, 7))
  end

  it "exposes load_tags/dump_tags and honors them" do
    expect(Yeptris::Psych.respond_to?(:load_tags)).to be(true)
    expect(Yeptris::Psych.load_tags).to eq({})

    tagged = <<~YAML
      --- !mygem/shape
      x: 1
      y: two
    YAML

    klass = Class.new do
      include Yeptris::Psych::Encodable
      attr_accessor :x, :y

      def init_with(coder)
        @x = coder["x"]
        @y = coder["y"]
      end
    end
    Yeptris::Psych.load_tags["!mygem/shape"] = klass
    begin
      obj = Yeptris::Psych.unsafe_load(tagged)
      expect(obj).to be_a(klass)
      expect(obj.x).to eq(1)
      expect(obj.y).to eq("two")
    ensure
      Yeptris::Psych.load_tags.delete("!mygem/shape")
    end

    point_klass = Class.new do
      include Yeptris::Psych::Encodable
      attr_accessor :x, :y

      def encode_with(coder)
        coder["x"] = @x
        coder["y"] = @y
      end

      def init_with(coder)
        @x = coder["x"]
        @y = coder["y"]
      end
    end
    point = point_klass.new
    point.x = 1
    point.y = 2
    Yeptris::Psych.dump_tags[point_klass] = "!mygem/point"
    begin
      # the dump_tags override rides the root tag. The emitter's
      # verbatim own-line tag form (!<...>) does not yet re-read
      # through the registry — the inline psych form is the follow-up
      # that closes the round-trip
      dumped = Yeptris::Psych.dump(point)
      expect(dumped).to include("!<!mygem/point>")
    ensure
      Yeptris::Psych.dump_tags.delete(point_klass)
    end
  end

  it "family 2: nil mapping keys ride Psych's ! form" do
    expect(Yeptris::YAML.dump({ nil => "nilkey" }, header: true))
      .to eq("---\n! '': nilkey\n")
    expect(Yeptris::Psych.dump(nil => "nilkey", "x" => 1))
      .to eq("---\n! '': nilkey\nx: 1\n")
  end
end
