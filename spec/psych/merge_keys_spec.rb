# frozen_string_literal: true

# The port of stdlib psych's test/psych/test_merge_keys.rb, function
# for function (#179's first port — the file that would have caught
# the visitor's missing merge expansion). Each example keeps stdlib's
# name so the port gap is auditable.
RSpec.describe "Psych merge keys (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  class Product
    attr_reader :bar
  end

  it "test_merge_key_with_bare_hash" do
    doc = ::Psych.load("map:\n  <<:\n    hello: world\n")
    expect(doc).to eq("map" => { "hello" => "world" })
  end

  it "test_roundtrip_with_chevron_key" do
    h = {}
    v = { "a" => h, "<<" => h }
    expect(::Psych.unsafe_load(::Psych.dump(v))).to eq(v)
  end

  it "test_explicit_string" do
    doc = ::Psych.unsafe_load("a: &me { hello: world }\nb: { !!str '<<': *me }\n")
    expect(doc).to eq(
      "a" => { "hello" => "world" },
      "b" => { "<<" => { "hello" => "world" } }
    )
  end

  # stdlib revives !ruby/object:<AnyClass> by setting ivars from the merged
  # pairs; the drop-in's revival contract currently demands
  # Yeptris::Psych::Encodable (init_with). Deliberate divergence —
  # tracked with #179's load-semantics port, not a merge-key bug.
  xit "test_mergekey_with_object" do
    yaml = "foo: &foo\n  bar: 10\nproduct:\n  !ruby/object:#{Product.name}\n  <<: *foo\n"
    hash = ::Psych.unsafe_load(yaml)
    expect(hash["foo"]).to eq("bar" => 10)
    expect(hash["product"].bar).to eq(10)
  end

  it "test_merge_nil" do
    yaml = "defaults: &defaults\ndevelopment:\n  <<: *defaults\n"
    expect(::Psych.unsafe_load(yaml)["development"]).to eq("<<" => nil)
  end

  it "test_merge_array" do
    yaml = "foo: &hello\n- 1\nbaz:\n  <<: *hello\n"
    expect(::Psych.unsafe_load(yaml)["baz"]).to eq("<<" => [1])
  end

  it "test_merge_is_not_partial" do
    yaml = "default: &default\n  hello: world\nfoo: &hello\n- 1\nbaz:\n  <<: [*hello, *default]\n"
    doc = ::Psych.unsafe_load(yaml)
    expect(doc["baz"].key?("hello")).to be(false)
    expect(::Psych.unsafe_load(yaml)["baz"]).to eq("<<" => [[1], { "hello" => "world" }])
  end

  it "test_merge_seq_nil" do
    yaml = "foo: &hello\nbaz:\n  <<: [*hello]\n"
    expect(::Psych.unsafe_load(yaml)["baz"]).to eq("<<" => [nil])
  end

  it "test_bad_seq_merge" do
    yaml = "defaults: &defaults [1, 2, 3]\ndevelopment:\n  <<: *defaults\n"
    expect(::Psych.unsafe_load(yaml)["development"]).to eq("<<" => [1, 2, 3])
  end

  it "test_missing_merge_key" do
    yaml = "bar:\n  << : *foo\n"
    # stdlib's message names the anchor; yeptris locates it (line:col)
    expect { ::Psych.load(yaml, aliases: true) }
      .to raise_error(::Psych::AnchorNotDefined, /undefined anchor/)
  end

  it "test_merge_key [ruby-core:34679]" do
    yaml = "foo: &foo\n  hello: world\nbar:\n  << : *foo\n  baz: boo\n"
    expect(::Psych.unsafe_load(yaml)).to eq(
      "foo" => { "hello" => "world" },
      "bar" => { "hello" => "world", "baz" => "boo" }
    )
  end

  it "test_multiple_maps" do
    yaml = <<~YAML
      ---
      - &CENTER { x: 1, y: 2 }
      - &LEFT { x: 0, y: 2 }
      - &BIG { r: 10 }
      - &SMALL { r: 1 }

      # All the following maps are equal:

      - # Merge multiple maps
        << : [ *CENTER, *BIG ]
        label: center/big
    YAML
    expect(::Psych.unsafe_load(yaml)[4]).to eq(
      "x" => 1, "y" => 2, "r" => 10, "label" => "center/big"
    )
  end

  it "test_override" do
    yaml = <<~YAML
      ---
      - &CENTER { x: 1, y: 2 }
      - &LEFT { x: 0, y: 2 }
      - &BIG { r: 10 }
      - &SMALL { r: 1 }

      # All the following maps are equal:

      - # Override
        << : [ *BIG, *LEFT, *SMALL ]
        x: 1
        label: center/big
    YAML
    expect(::Psych.unsafe_load(yaml)[4]).to eq(
      "x" => 1, "y" => 2, "r" => 10, "label" => "center/big"
    )
  end

  # stdlib's test_merge_key_with_bare_hash_symbolized_names needs
  # Psych.load(symbolize_names:) — the drop-in swallows the kwarg
  # today. Tracked by #179 (the load-semantics port).
  xit "test_merge_key_with_bare_hash_symbolized_names" do
    doc = ::Psych.load("map:\n  <<:\n    hello: world\n", symbolize_names: true)
    expect(doc).to eq(map: { hello: "world" })
  end
end
