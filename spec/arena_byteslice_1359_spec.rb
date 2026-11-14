# frozen_string_literal: true

# yeptris#1359: the recorder arena is sliced by BYTES. The record
# fields (value/anchor/tag off+len) are byte offsets into the arena;
# walk() tags the arena UTF-8, where String#[] counts CHARACTERS. After
# the first multibyte char a char-indexed slice drifts (wrong text) and
# past the arena's char count it is nil (NoMethodError in scan_by_tag).
# 0.6.66's safe_load sends any source with a `*` or `!` byte through
# walk(), which surfaced the latent defect on the relaton BIPM data.
require "yeptris/psych"
require "psych"
require "date"

RSpec.describe "recorder arena byte slices (#1359)" do
  def via_records(src)
    Yeptris::Materializer.new.materialize_records(
      *Yeptris::Materializer.drain(src, schema: :compat_11)
    ).first
  end

  REDUCTIONS = {
    "drifted slice" =>
      "metadata:\n  title: 1e réunion de la CGPM\n  identifier: 1\n  note: la *sanctionne*\n",
    "slice past the char count" => "a: éééééééé\nb: c\nd: la *e*\n"
  }.freeze

  REDUCTIONS.each do |label, src|
    it "safe_load matches stdlib Psych (#{label})" do
      expect(Yeptris::Psych.safe_load(src)).to eq(::Psych.safe_load(src))
    end

    it "materialize_records matches stdlib Psych (#{label})" do
      expect(via_records(src)).to eq(::Psych.safe_load(src))
    end
  end

  it "resolves a non-ASCII anchor and alias after multibyte content" do
    # libyaml (stdlib Psych) refuses a non-ASCII anchor name; YAML 1.2
    # allows it (ns-anchor-char), so the expectation is spelled out
    src = "x: ééé\na: &ancré [1, 2]\nb: *ancré\nm: &mé {k: v}\nn: *mé\ns: &sé ü\nt: *sé\n"
    want = { "x" => "ééé", "a" => [1, 2], "b" => [1, 2], "m" => { "k" => "v" },
             "n" => { "k" => "v" }, "s" => "ü", "t" => "ü" }
    got = Yeptris::Psych.safe_load(src, aliases: true)
    expect(got).to eq(want)
    expect(got["b"]).to equal(got["a"])
    expect(via_records(src)).to eq(want)
  end

  it "reads the tag text after multibyte content (walk and gate)" do
    src = "x: ééééé\nk: !ruby/symbol ça\ns: !!str 12\n"
    want = ::Psych.safe_load(src, permitted_classes: [Symbol])
    expect(Yeptris::Psych.safe_load(src, permitted_classes: [Symbol])).to eq(want)
    expect(want["k"]).to eq(:ça)
  end

  # check_records reads the tag before walk() tags the arena UTF-8, so
  # it is right today; this pins it against a reorder
  it "gates the right tag text after multibyte content" do
    src = "x: ééééé\nk: !ruby/symbol ça\n"
    expect { Yeptris::Psych.safe_load(src) }
      .to raise_error(Yeptris::Psych::DisallowedClass, %r{ruby/symbol})
  end

  # A UTF-8-tagged arena fed straight to the gate: the two
  # check_records slices must still read by bytes
  it "reads tag and timestamp text by bytes in check_records" do
    src = "x: éééééééééééé\nk: !ruby/symbol ça\nwhen: 2001-12-14\n"
    flat, arena = Yeptris::Materializer.drain(src, schema: :compat_11)
    arena = arena.dup.force_encoding(Encoding::UTF_8)
    gate = ->(permitted) { Yeptris::Psych.send(:check_records, flat, arena, permitted, false) }
    expect { gate.call([Date]) }
      .to raise_error(Yeptris::Psych::DisallowedClass, %r{ruby/symbol})
    expect { gate.call([Symbol, Time]) }
      .to raise_error(Yeptris::Psych::DisallowedClass, /Date/)
    expect { gate.call([Symbol, Date]) }.not_to raise_error
  end

  it "resolves the timestamp text in the gate after multibyte content" do
    # the `!` byte sends the source onto the checked walk
    src = "x: éééééééééééé\nwhen: 2001-12-14\nt: !!str y\n"
    expect { Yeptris::Psych.safe_load(src, permitted_classes: [Time]) }
      .to raise_error(Yeptris::Psych::DisallowedClass, /Date/)
    expect(Yeptris::Psych.safe_load(src, permitted_classes: [Date]))
      .to eq(::Psych.safe_load(src, permitted_classes: [Date]))
  end

  # The two relaton BIPM fixtures from the report (BSD-2, relaton/relaton
  # spec/bipm/fixtures/{cgpm,cipm}/meetings-fr/).
  Dir[File.expand_path("fixtures/relaton_bipm/*.yml", __dir__)].sort.each do |path|
    it "loads #{File.basename(path)} like stdlib Psych" do
      src = File.read(path, encoding: "UTF-8")
      opts = { permitted_classes: [Date, Time] }
      expect(Yeptris::Psych.safe_load(src, **opts)).to eq(::Psych.safe_load(src, **opts))
    end
  end
end
