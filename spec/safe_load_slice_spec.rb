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

  # The #862 drain-lane cut: clean sources ride the marshal lane (one
  # C call), gated sources ride the recorder drain (the gate reads the
  # flat record array, the build rides the record stack machine) — no
  # per-node FFI anywhere. The pins below hold the lanes to the
  # DOM-walk results they replaced.
  it "types permitted timestamps on the marshal-refusal lane" do
    res = Yeptris::Psych.safe_load(GATE_FREE)
    expect(res["when"]).to eq(::Date.new(2001, 12, 14))
    expect(res["when"]).to be_a(::Date)
  end

  it "applies the timestamp gate on the records lane (Time vs Date by shape)" do
    expect do
      Yeptris::Psych.safe_load("when: 2001-12-14T21:59:43.10-05:00\n", permitted_classes: [::Date])
    end.to raise_error(Yeptris::Psych::DisallowedClass, "Tried to load unspecified class: Time")
    expect do
      Yeptris::Psych.safe_load("when: 2001-12-14\n", permitted_classes: [::Time])
    end.to raise_error(Yeptris::Psych::DisallowedClass, "Tried to load unspecified class: Date")
  end

  it "skips timestamp resolution when both classes are permitted" do
    # the facade default: the gate cannot fire — a MALFORMED timestamp
    # text must not raise, it loads as the String the resolver yields
    res = Yeptris::Psych.safe_load("when: 2001-99-99\n")
    expect(res["when"]).to eq("2001-99-99")
  end

  it "keeps alias identity on the records lane (aliases: true)" do
    res = Yeptris::Psych.safe_load("a: &x [1]\nb: *x\n", aliases: true)
    expect(res["a"].equal?(res["b"])).to be(true)
    expect(res).to eq("a" => [1], "b" => [1])
  end

  it "refuses aliases before resolution (AliasesError for a missing anchor too)" do
    expect do
      Yeptris::Psych.safe_load("x: *missing\n")
    end.to raise_error(Yeptris::Psych::AliasesError, "Unknown alias")
  end

  it "raises AnchorNotDefined with the engine phrase under opt-in" do
    expect do
      Yeptris::Psych.safe_load("x: *missing\n", aliases: true)
    end.to raise_error(Yeptris::Psych::AnchorNotDefined, /undefined anchor/)
  end

  it "allows the bare non-specific tag on both faces (the nil-key form)" do
    # the record carries tag text "!" verbatim; the DOM face saw tag
    # nil — both must ALLOW it (it names no class)
    expect(Yeptris::Psych.safe_load("k: ! \x27\x27\n")).to eq("k" => "")
    expect(Yeptris::Psych.safe_load("! '': v\n")["!"]).to eq("v").or eq(nil)
  end

  it "materializes !ruby/symbol through the records lane (the tag-text law)" do
    res = Yeptris::Psych.safe_load("foo: !ruby/symbol bar\n", permitted_classes: [::Symbol])
    expect(res).to eq("foo" => :bar)
  end

  it "takes the first document of a stream on every lane" do
    clean = "---\na: 1\n---\nb: 2\n"
    gated = "---\na: &x 1\n---\nb: 2\n"
    expect(Yeptris::Psych.safe_load(clean)).to eq("a" => 1)
    expect(Yeptris::Psych.safe_load(gated, aliases: true)).to eq("a" => 1)
  end

  it "refuses a cross-document alias like the DOM face (anchors are per-document)" do
    expect do
      Yeptris::Psych.safe_load("---\na: &x 1\n---\nb: *x\n", aliases: true)
    end.to raise_error(Yeptris::Psych::AnchorNotDefined, /undefined anchor/)
  end

  it "rides the marshal lane on plain sources (typing parity spot checks)" do
    res = Yeptris::Psych.safe_load("i: 42\nbig: 12345678901234567890123\nf: 1.5\nb: true\nn: ~\n")
    expect(res["i"]).to eq(42)
    expect(res["big"]).to eq(12_345_678_901_234_567_890_123)
    expect(res["f"]).to eq(1.5)
    expect(res["b"]).to be(true)
    expect(res["n"]).to be_nil
  end
end
