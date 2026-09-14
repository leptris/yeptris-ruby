# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "Yeptris::JSON.dump" do
  # compact byte-parity needs yeptris_serialize_json_ex (C >= 0.2.5);
  # older vendored libraries fall back to the spaced form
  it "is byte-identical to JSON.generate for the core types (compact library)" do
    skip "needs yeptris_serialize_json_ex (C >= 0.2.5)" unless ::Yeptris::FFI::JSON_EX

    objs = [
      {}, [], "", "plain", "esc\"\\\n\t/", "42", "true", 0, -1,
      9223372036854775807, -9223372036854775808, 3.5, -0.0, 1e-3,
      true, false, nil,
      {"a" => 1, "b" => [true, nil, "x"], "c" => {"d" => []}},
      [({"k" => :sym}), nil, [[]]],
      {"nested" => {"deep" => [{"deeper" => 1}]}}
    ]
    objs.each do |obj|
      expect(Yeptris::JSON.dump(obj)).to eq(JSON.generate(obj))
    end
  end

  it "generates valid strict JSON load can re-parse (any library)" do
    obj = {"a" => 1, "b" => [true, nil, "x"], "c" => {"d" => []}, "q" => "42"}
    text = Yeptris::JSON.dump(obj)
    expect(Yeptris::JSON.load(text)).to eq(obj)
    expect(JSON.parse(text)).to eq(obj)
    expect(text).not_to end_with("\n")
  end

  it "round-trips through load" do
    obj = {"id" => 7, "name" => "alpha", "vals" => [1, 2.5, true, nil], "ok" => false}
    expect(Yeptris::JSON.load(Yeptris::JSON.dump(obj))).to eq(obj)
  end

  it "rejects unsupported objects" do
    expect { Yeptris::JSON.dump(Object.new) }.to raise_error(Yeptris::JSON::DumpError)
  end
end

RSpec.describe "Yeptris::JSON.tape_engine (the FFI tier)" do
  # Native, when built, shadows the tape engine in every load-path
  # spec — the release smoke (source gem, no bundle) is the only other
  # place it runs. This forces the FFI tier directly.
  it "matches JSON.parse on randomized documents" do
    srand(4242)
    300.times do
      src = JSON.generate(
        Hash[(0...15).map do |i|
          ["k#{i}", [rand, rand(10**12), nil, true, false, "s#{i}", 1e-3 * i,
                     {"n" => [i, -i]}][rand(8)]]
        end]
      )
      expect(Yeptris::JSON.tape_engine(src)).to eq(JSON.parse(src))
    end
  end

  it "handles scalar roots and float shapes" do
    expect(Yeptris::JSON.tape_engine('{"a": 1e3}')).to eq({"a" => 1000.0})
    expect(Yeptris::JSON.tape_engine("3.5")).to eq(3.5)
    expect(Yeptris::JSON.tape_engine("42")).to eq(42)
    expect(Yeptris::JSON.tape_engine("true")).to eq(true)
    expect(Yeptris::JSON.tape_engine("null")).to eq(nil)
    expect(Yeptris::JSON.tape_engine('"solo"')).to eq("solo")
  end

  it "rebuilds exact bignums" do
    expect(Yeptris::JSON.tape_engine('{"b": 92233720368547758089999}'))
      .to eq({"b" => 92233720368547758089999})
  end
end

RSpec.describe "Yeptris::JSON.tape_engine escape decoding" do
  it "decodes \\u escapes, surrogate pairs, and simple escapes like JSON.parse" do
    inputs = [
      '{"u": "\\u00e9\\ud83d\\ude00"}',
      '{"k": "\\u0041\\n\\t\\"\\\\\\/"}',
      '{"b": "\\b\\f\\r"}',
      '{"mix": "héllo \\u0041 😀"}',
      '{"zero": "\\u0000x"}'
    ]
    inputs.each do |src|
      expect(Yeptris::JSON.tape_engine(src)).to eq(JSON.parse(src))
    end
  end
end
