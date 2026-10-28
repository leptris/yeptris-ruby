# frozen_string_literal: true

require "spec_helper"

# yeptris-ruby#322: the CBOR dump face's marshal route (Marshal.dump
# bytes -> yeptris_cbor_from_marshal -> one CBOR item) must be
# byte-identical to the YAMLTree walk on every shape it accepts. The
# route swaps on face availability and on the C face's UNSUPPORTED
# answer, so any divergence would change dumped bytes with the engine
# version.
RSpec.describe "Yeptris::CBOR.dump marshal-route parity (yeptris-ruby#322)" do
  let(:corpus) do
    {
      "scalars" => { "nil" => nil, "t" => true, "f" => false,
                     "i" => 42, "neg" => -17, "fl" => 1.5 },
      "bignum" => 2**40,
      "strings" => { "plain" => "hello world", "empty" => "",
                     "utf8" => "héllo wörld ✓", "esc" => "a\"b\\c\nd" },
      "arrays" => [[], [1, 2, 3], %w[a b c], [[1], [2, [3]]]],
      "hashes" => [{}, { "a" => 1 }, { "deep" => { "inner" => { "leaf" => nil } } }],
      "symbols" => { a: :b },
      "reserved" => ["undefined", "simple(32)", "simple(7)", "simple(24)"],
      "shared" => ["dup", "dup"],
      "users" => (1..50).map { |i|
        { "id" => i, "name" => "User #{i}", "active" => i.even?,
          "score" => i * 1.5, "tags" => %w[a b c],
          "meta" => { "deep" => { "x" => i } } }
      },
    }
  end

  # the pre-#322 route, spelled once: YAMLTree -> document -> C encode
  def tree_walk(obj, canonical)
    docs = ::Yeptris::CBOR.build_documents([obj])
    begin
      ::Yeptris::CBOR.encode_one(docs[0], canonical)
    ensure
      docs.each(&:free)
    end
  end

  it "dumps byte-identically to the tree walk in both key orders" do
    skip "marshal dump face unavailable" unless ::Yeptris::FFI::MARSHAL_CBOR

    [true, false].each do |canonical|
      via_face = ::Yeptris::CBOR.marshal_cbor_dump(corpus, canonical)
      expect(via_face).not_to be_nil, "canonical=#{canonical}: the corpus is fast-path eligible"
      expect(via_face).to eq(tree_walk(corpus, canonical)), "canonical=#{canonical}"
    end
    # and through the public entry point (route selected for us)
    expect(::Yeptris::CBOR.dump(corpus)).to eq(tree_walk(corpus, true))
    expect(::Yeptris::CBOR.dump(corpus, canonical: false))
      .to eq(tree_walk(corpus, false))
  end

  it "falls back to the tree walk when the face is absent" do
    skip "marshal dump face unavailable" unless ::Yeptris::FFI::MARSHAL_CBOR

    orig = ::Yeptris::CBOR.method(:marshal_cbor_dump)
    begin
      ::Yeptris::CBOR.define_singleton_method(:marshal_cbor_dump) { |_obj, _canon| nil }
      expect(::Yeptris::CBOR.dump(corpus)).to eq(tree_walk(corpus, true))
    ensure
      ::Yeptris::CBOR.define_singleton_method(:marshal_cbor_dump, orig)
    end
  end

  it "declines shapes with no exact fast-path spelling and keeps the walk's bytes" do
    skip "marshal dump face unavailable" unless ::Yeptris::FFI::MARSHAL_CBOR

    # nil map key, binary string, wide bignum: the face answers nil and
    # the walk owns the result (here: an error for the first two, a
    # float re-render for the bignum)
    expect(::Yeptris::CBOR.marshal_cbor_dump({ nil => 1 }, true)).to be_nil
    expect { ::Yeptris::CBOR.dump({ nil => 1 }) }
      .to raise_error(::Yeptris::CBOR::UnencodableError)
    expect(::Yeptris::CBOR.marshal_cbor_dump(["\xff".b], true)).to be_nil
    expect { ::Yeptris::CBOR.dump(["\xff".b]) }
      .to raise_error(::Yeptris::CBOR::UnencodableError)
    expect(::Yeptris::CBOR.marshal_cbor_dump(2**70, true)).to be_nil
    expect(::Yeptris::CBOR.dump(2**70)).to eq(tree_walk(2**70, true))
  end

  it "leaves Marshal-undumpable hosts to the walk's DumpError" do
    skip "marshal dump face unavailable" unless ::Yeptris::FFI::MARSHAL_CBOR

    expect(::Yeptris::CBOR.marshal_cbor_dump(proc {}, true)).to be_nil
    expect { ::Yeptris::CBOR.dump(proc {}) }.to raise_error(Yeptris::DumpError)
    expect { ::Yeptris::CBOR.dump(Object.new) }
      .to raise_error(::Yeptris::CBOR::UnencodableError)
    klass = Struct.new(:a)
    expect { ::Yeptris::CBOR.dump(klass.new(1)) }
      .to raise_error(::Yeptris::CBOR::UnencodableError)
    expect { ::Yeptris::CBOR.dump(Set[1, 2]) }
      .to raise_error(::Yeptris::CBOR::UnencodableError)
  end

  it "keeps the whole 5k-row dump inside the wave noise band" do
    skip "marshal dump face unavailable" unless ::Yeptris::FFI::MARSHAL_CBOR

    big = { "rows" => (1..5000).map { |i| { "i" => i, "s" => "row #{i}" } } }
    expect(::Yeptris::CBOR.marshal_cbor_dump(big, true)).not_to be_nil
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ::Yeptris::CBOR.dump(big)
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # the tree walk ran 84-141 ms here; the marshal route ~17-35 ms
    expect((t1 - t0) * 1000).to be < 200
  end
end
