# frozen_string_literal: true

require "psych"

RSpec.describe "Psych.load options" do
  # stdlib parity: load forwarded symbolize_names/fallback to
  # safe_load, and the ** swallowed both silently (audit 2026-10-31)

  it "symbolize_names rides load" do
    expect(Yeptris::Psych.load("a: 1\nb: [x]\n", symbolize_names: true))
      .to eq(a: 1, b: ["x"])
  end

  it "fallback answers for an empty stream" do
    expect(Yeptris::Psych.load("", fallback: 42)).to eq(42)
  end

  it "fallback does not shadow documents whose content is nil" do
    # documents exist; stdlib returns their nil content
    expect(Yeptris::Psych.load("---\n", fallback: 42)).to be_nil
    expect(Yeptris::Psych.load("---\n---\n", fallback: 42)).to be_nil
  end

  it "safe_load keeps its symbolize_names behavior" do
    expect(Yeptris::Psych.safe_load("k: v\n", symbolize_names: true))
      .to eq(k: "v")
  end
end

RSpec.describe "event-level scalar encodings" do
  # the parser's arena rode ASCII-8BIT; stdlib Psych hands handlers
  # UTF-8 and TreeBuilder propagates it into node values
  # (audit 2026-10-31)

  it "hands handler scalars as UTF-8" do
    got = []
    handler = Object.new
    handler.define_singleton_method(:event_location) { |*| }
    handler.define_singleton_method(:start_stream) { |*| }
    handler.define_singleton_method(:end_stream) { |*| }
    handler.define_singleton_method(:start_document) { |*| }
    handler.define_singleton_method(:end_document) { |*| }
    handler.define_singleton_method(:start_sequence) { |*| }
    handler.define_singleton_method(:end_sequence) { |*| }
    handler.define_singleton_method(:start_mapping) { |*| }
    handler.define_singleton_method(:end_mapping) { |*| }
    handler.define_singleton_method(:alias) { |*| }
    handler.define_singleton_method(:scalar) do |value, *_rest|
      got << value
    end
    Yeptris::Psych::Parser.new(handler).parse("a: caf\xc3\xa9\n")
    expect(got).to include("café")
    expect(got.map(&:encoding).uniq).to eq([Encoding::UTF_8])
  end

  it "TreeBuilder node values carry UTF-8" do
    tree = ::Psych.parse("a: caf\xc3\xa9\n")
    v = tree.children.first.children.last.value
    expect(v).to eq("café")
    expect(v.encoding).to eq(Encoding::UTF_8)
  end
end
