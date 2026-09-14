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
