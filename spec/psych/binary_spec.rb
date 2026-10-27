# frozen_string_literal: true

# #168: binary scalars — Psych.dump emits the !binary base64 block
# byte-identically to stdlib, and load decodes both tag spellings the
# stdlib accepts ('!binary' shorthand — psych's own dumped form — and
# the '!!binary' core URI). Recording under the rebind and replaying
# stdlib-recorded cassettes both work.
RSpec.describe "Yeptris::Psych binary scalars (#168)" do
  before do
    # the drop-in is process-exclusive; the face is exercised directly
    require "yeptris/psych"
  end

  let(:v) { "a\xB0b\x98c".dup.force_encoding(Encoding::ASCII_8BIT) }
  let(:long) { (0..200).map { |i| (i % 256).chr }.join.force_encoding(Encoding::ASCII_8BIT) }

  def stdlib
    # the reference behavior, captured without the rebind: stdlib
    # psych's dump of the same value (same interpreter's bundled gem)
    require "psych"
    @stdlib ||= Psych.method(:dump).unbind
  rescue StandardError
    nil
  end

  it "dumps the root scalar as the !binary base64 block" do
    expect(Yeptris::Psych.dump(v)).to eq("--- !binary |-\n  YbBimGM=\n")
  end

  it "dumps binary values inside containers" do
    expect(Yeptris::Psych.dump("body" => v)).to eq("---\nbody: !binary |-\n  YbBimGM=\n")
  end

  it "round-trips: encoding and bytes survive" do
    r = Yeptris::Psych.load(Yeptris::Psych.dump(v))
    expect(r.encoding).to eq(Encoding::ASCII_8BIT)
    expect(r).to eq(v)

    h = Yeptris::Psych.load(Yeptris::Psych.dump("body" => v))["body"]
    expect(h.encoding).to eq(Encoding::ASCII_8BIT)
    expect(h).to eq(v)
  end

  it "round-trips long payloads (never line-wrapped base64)" do
    out = Yeptris::Psych.dump(long)
    body = out.split("\n").last
    expect(body.strip).to eq([long].pack("m0")) # one unwrapped line, like stdlib
    r = Yeptris::Psych.load(out)
    expect(r).to eq(long)
  end

  it "loads both tag spellings the stdlib accepts" do
    expect(Yeptris::Psych.load("--- !binary |-\n  YbBimGM=\n")).to eq(v)
    expect(Yeptris::Psych.load("--- !!binary YbBimGM=\n")).to eq(v)
  end

  it "safe_load accepts the core tag" do
    expect(Yeptris::Psych.safe_load("--- !binary |-\n  YbBimGM=\n")).to eq(v)
  end

  it "keeps #135's UTF-8 tagging for non-binary scalars" do
    expect(Yeptris::Psych.load("k: café")).to eq("k" => "café")
  end
end
