# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "Yeptris::JSON.dump pretty mode (yeptris-ruby#304)" do
  # pretty byte-parity needs yeptris_serialize_json_pretty; older
  # vendored libraries raise through the feature detect
  it "is byte-identical to JSON.pretty_generate for the core types" do
    skip "needs yeptris_serialize_json_pretty" unless ::Yeptris::FFI::JSON_PRETTY

    objs = [
      {}, [], "", "plain", "esc\"\\\n\t/", "42", "true", 0, -1,
      9223372036854775807, -9223372036854775808, 3.5, -0.0, 1e-3,
      true, false, nil,
      {"a" => 1, "b" => [true, nil, "x"], "c" => {"d" => []}},
      [({"k" => :sym}), nil, [[]]],
      {"nested" => {"deep" => [{"deeper" => 1}]}},
      [[1, [2, 3]], {"k" => [{}]}],
      {"x" => 1.0e-7}
    ]
    objs.each do |obj|
      expect(Yeptris::JSON.dump(obj, pretty: true)).to eq(JSON.pretty_generate(obj))
    end
  end

  it "keeps empty collections inline and one entry per line" do
    skip "needs yeptris_serialize_json_pretty" unless ::Yeptris::FFI::JSON_PRETTY

    text = Yeptris::JSON.dump({"f" => [], "g" => {}, "b" => [1, 2]}, pretty: true)
    expect(text).to eq(<<~JSON.chomp)
      {
        "f": [],
        "g": {},
        "b": [
          1,
          2
        ]
      }
    JSON
  end

  it "carries the indent unit verbatim per depth" do
    skip "needs yeptris_serialize_json_pretty" unless ::Yeptris::FFI::JSON_PRETTY

    obj = {"a" => [1]}
    expect(Yeptris::JSON.dump(obj, pretty: true, indent: "\t"))
      .to eq(JSON.pretty_generate(obj, indent: "\t"))
    expect(Yeptris::JSON.dump(obj, pretty: true, indent: "")).to eq(JSON.pretty_generate(obj, indent: ""))
  end

  it "rides the #651 float contract in the pretty shape" do
    skip "needs yeptris_serialize_json_pretty" unless ::Yeptris::FFI::JSON_PRETTY

    floats = [0.1, 100.0, -0.0, 5e-324, 1.0e-320, 1.0e20, 1.0e-7, 1e300,
              2.2250738585072014e-308, 3.141592653589793]
    floats.each do |f|
      obj = {"x" => f}
      expect(Yeptris::JSON.dump(obj, pretty: true)).to eq(JSON.pretty_generate(obj))
    end
  end

  it "round-trips through load" do
    skip "needs yeptris_serialize_json_pretty" unless ::Yeptris::FFI::JSON_PRETTY

    obj = {"id" => 7, "vals" => [1, 2.5, true, nil], "ok" => false}
    text = Yeptris::JSON.dump(obj, pretty: true)
    expect(Yeptris::JSON.load(text)).to eq(obj)
    expect(JSON.parse(text)).to eq(obj)
  end

  it "raises DumpError on libraries without the pretty entry" do
    skip "the vendored library already has the pretty entry" if ::Yeptris::FFI::JSON_PRETTY

    expect { Yeptris::JSON.dump({}, pretty: true) }.to raise_error(Yeptris::JSON::DumpError)
  end
end
