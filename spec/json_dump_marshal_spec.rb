# frozen_string_literal: true

require "spec_helper"

# yeptris-ruby#322: the dump face's marshal route (Marshal.dump bytes
# -> yeptris_json_from_marshal -> JSON text) must be byte-identical to
# the per-node place_obj route on the shared corpus — the routes swap
# based on face availability, so any divergence would surface as a
# dump that changes bytes when the engine version changes.
RSpec.describe "Yeptris::JSON.dump marshal-route parity" do
  let(:corpus) do
    {
      "scalars" => { "nil" => nil, "t" => true, "f" => false,
                     "i" => 42, "neg" => -17, "f" => 1.5 },
      "bignum" => 2**40,
      "strings" => { "plain" => "hello world", "empty" => "",
                     "utf8" => "héllo wörld ✓", "esc" => "a\"b\\c\nd" },
      "arrays" => [[], [1, 2, 3], %w[a b c], [[1], [2, [3]]]],
      "hashes" => [{}, { "a" => 1 }, { "x" => { "y" => { "z" => nil } } }],
      "users" => (1..50).map { |i|
        { "id" => i, "name" => "User #{i}", "active" => i.even?,
          "score" => i * 1.5, "tags" => %w[a b c],
          "meta" => { "deep" => { "x" => i } } }
      },
    }
  end

  it "dumps byte-identically to the per-node route" do
    skip "marshal dump face unavailable" unless ::Yeptris::FFI::MARSHAL_JSON
    fallback = ::Yeptris::JSON.send(:marshal_engine,
                                    JSON.generate(corpus),
                                    ::Yeptris::FFI::MARSHAL_STRICT_DUP_KEYS ? 1 : 0)
    expect(fallback).to eq(corpus) # sanity: the corpus survives the round trip
    via_face = ::Yeptris::JSON.dump(corpus)
    expect(via_face).to eq(JSON.generate(corpus))
  end

  it "keeps the marshal route on the 2 MB corpus within the wave noise band" do
    skip "marshal dump face unavailable" unless ::Yeptris::FFI::MARSHAL_JSON
    big = { "rows" => (1..5000).map { |i| { "i" => i, "s" => "row #{i}" } } }
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ::Yeptris::JSON.dump(big)
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect((t1 - t0) * 1000).to be < 200 # the #322 dump was 20.8 ms; the route is ~4 ms
  end
end
