# frozen_string_literal: true

# TODO.cbor/04 — the Ruby CBOR surface over the shared FFI document:
# dump/load (single item) and dump_sequence/load_sequence (RFC 8742).
# Skipped cleanly when the vendored library predates the codec.

require "spec_helper"

RSpec.describe Yeptris::CBOR, if: Yeptris::CBOR.available? do
  def round_trip(obj)
    Yeptris::CBOR.load(Yeptris::CBOR.dump(obj))
  end

  it "round-trips the JSON data model" do
    values = [
      nil,
      true,
      false,
      0,
      -1,
      2**31,          # beyond int32 (the LLP64 regression family)
      2**40,          # int64 territory
      -2**40,
      2.5,
      -0.0,
      "",
      "text",
      [],
      {},
      {"a" => [1, 2.5, nil, true, "x"], "b" => {"nested" => -3}},
      [[[["deep"]]]],
    ]
    values.each { |v| expect(round_trip(v)).to eq(v) }
  end

  it "produces canonical bytes for a known shape" do
    # {"a": [1, 2.5, null, true, "x"], "b": {"nested": -3}} — keys
    # sorted bytewise (a < b), minimal lengths, preferred floats
    expect(Yeptris::CBOR.dump({"b" => {"nested" => -3}, "a" => [1, 2.5, nil, true, "x"]}).unpack1("H*"))
      .to eq("a261618501f94100f6f561786162a1666e657374656422")
  end

  it "is byte-stable across repeated encodes" do
    v = {"z" => [1, 2], "a" => {"k" => 3.25}}
    expect(Yeptris::CBOR.dump(v)).to eq(Yeptris::CBOR.dump(v))
  end

  it "encodes without canonical key sorting on request (insertion order)" do
    canonical = Yeptris::CBOR.dump({"b" => 1, "a" => 2})
    insertion = Yeptris::CBOR.dump({"b" => 1, "a" => 2}, canonical: false)
    expect(canonical.unpack1("H*")).to eq("a2616102616201")
    expect(insertion.unpack1("H*")).to eq("a2616201616102")
  end

  it "round-trips CBOR Sequences (RFC 8742)" do
    items = [1, {"k" => "v"}, [true], nil, "tail"]
    expect(Yeptris::CBOR.load_sequence(Yeptris::CBOR.dump_sequence(items))).to eq(items)
  end

  it "treats an empty sequence as empty (valid per RFC 8742)" do
    expect(Yeptris::CBOR.load_sequence("")).to eq([])
  end

  it "raises ParseError on malformed or truncated input" do
    expect { Yeptris::CBOR.load("ffff") }.to raise_error(Yeptris::ParseError)
    expect { Yeptris::CBOR.load("\x1a\x00".b) }.to raise_error(Yeptris::ParseError)
  end

  it "rejects trailing bytes after a single item (sequences have their own API)" do
    expect { Yeptris::CBOR.load("\x01\x02".b) }.to raise_error(Yeptris::ParseError)
  end

  it "strict mode rejects non-minimal length arguments" do
    # 0x18 0x01 = uint 1 encoded with a one-byte argument — non-minimal
    expect { Yeptris::CBOR.load("\x18\x01".b, strict: true) }
      .to raise_error(Yeptris::ParseError)
    expect(Yeptris::CBOR.load("\x18\x01".b)).to eq(1)
  end

  it "survives GC after loading (the document ownership path)" do
    50.times { round_trip({"deep" => [{"x" => [1, 2]}]}) }
    GC.start
    expect(round_trip(["after", "gc"])).to eq(["after", "gc"])
  end

  it "round-trips a large mapping (key interning path)" do
    v = (1..1000).to_h { |i| ["key#{i}", i] }
    expect(round_trip(v)).to eq(v)
  end
end
