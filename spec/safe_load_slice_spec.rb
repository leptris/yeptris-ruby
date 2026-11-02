# frozen_string_literal: true

# The safe_load single-pass slice (#862): a source with no `*` and no
# `!` byte cannot carry an alias or an explicit tag (the parser cannot
# build either without the byte), and the marshal builder refuses
# timestamps and merge keys — so its success proves check() could not
# have raised and the gate walk is skipped. These pins cover the edges
# the proof rests on: a marshal REFUSAL (timestamp, literal merge) on
# a gate-free source must fall back to the checked walk and behave
# exactly as before.
require "yeptris/psych"
require "stringio"

RSpec.describe "safe_load single-pass slice (#862)" do
  GATE_FREE = "when: 2001-12-14\nplain: text\nlist:\n- 1\n- 2\n"

  it "still raises DisallowedClass for a timestamp on a gate-free source" do
    # no `*`, no `!` — yet the marshal refusal (timestamps) must drop
    # the load onto the checked walk, which enforces the Date gate
    expect do
      Yeptris::Psych.safe_load(GATE_FREE, permitted_classes: [])
    end.to raise_error(Yeptris::Psych::DisallowedClass, "Tried to load unspecified class: Date")
  end

  it "still types the timestamp when Date is permitted" do
    res = Yeptris::Psych.safe_load(GATE_FREE)
    expect(res["when"]).to eq(::Date.new(2001, 12, 14))
  end

  it "keeps merge semantics for a literal merge on a gate-free source" do
    # `<<: {…}` carries no gate byte and the marshal builder refuses
    # merges — the checked walk must apply it, not emit a literal key
    res = Yeptris::Psych.safe_load("base:\n  <<: {p: 1}\n")
    expect(res).to eq("base" => { "p" => 1 })
  end

  it "still refuses aliases without opt-in" do
    expect do
      Yeptris::Psych.safe_load("a: &x 1\nb: *x\n")
    end.to raise_error(Yeptris::Psych::AliasesError)
  end

  it "still refuses disallowed tags" do
    expect do
      Yeptris::Psych.safe_load("obj: !ruby/object:NoSuchKlass\n  foo: 1\n")
    end.to raise_error(Yeptris::Psych::DisallowedClass, /NoSuchKlass/)
  end

  it "answers nil for the legal empty stream" do
    expect(Yeptris::Psych.safe_load("")).to be_nil
    expect(Yeptris::Psych.safe_load("---\n")).to be_nil
  end

  it "honors symbolize_names on the fast path" do
    res = Yeptris::Psych.safe_load("alpha: 1\nbeta: two\n", symbolize_names: true)
    expect(res).to eq(alpha: 1, beta: "two")
  end

  it "reads IO-like input once (the boundary move)" do
    res = Yeptris::Psych.safe_load(StringIO.new("io-key: loaded\n"))
    expect(res).to eq("io-key" => "loaded")
  end

  it "keeps the UTF-8 retag on the fast path (a BINARY source reads UTF-8)" do
    src = "k: café\n".dup.force_encoding(::Encoding::ASCII_8BIT)
    res = Yeptris::Psych.safe_load(src)
    expect(res["k"].encoding).to eq(::Encoding::UTF_8)
    expect(res["k"]).to eq("café")
  end
end
