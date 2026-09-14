# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "Yeptris::JSON.dump" do
  it "is byte-identical to JSON.generate for the core types" do
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

  it "round-trips through load" do
    obj = {"id" => 7, "name" => "alpha", "vals" => [1, 2.5, true, nil], "ok" => false}
    expect(Yeptris::JSON.load(Yeptris::JSON.dump(obj))).to eq(obj)
  end

  it "rejects unsupported objects" do
    expect { Yeptris::JSON.dump(Object.new) }.to raise_error(Yeptris::JSON::DumpError)
  end
end
