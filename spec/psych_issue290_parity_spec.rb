# frozen_string_literal: true

require "spec_helper"
require "yeptris/yaml"

# Issue #290: the six remaining Psych byte-parity families. The oracle
# is stdlib Psych.dump (the canon format_yaml contract: canonical
# output bytes are the product).
RSpec.describe "Psych dump byte parity (issue #290)" do
  def parity(obj)
    expect(Yeptris::YAML.dump(obj, header: true)).to eq(::YAML.dump(obj))
  end

  before(:all) { require "yaml" unless defined?(::YAML) }

  it "family 1/6: nil values ride bare (nested too)" do
    parity("z" => nil)
    parity("outer" => { "inner" => nil, "x" => 1 })
  end

  it "family 2: nil seq items are bare dashes" do
    parity([1, nil])
    parity([nil, "a", nil])
  end

  it "family 3: special floats ride the YAML words" do
    parity("inf" => Float::INFINITY, "nan" => Float::NAN, "ninf" => -Float::INFINITY,
           "plain" => 2.5)
  end

  it "family 4: interior-newline strings ride literal blocks" do
    parity("text" => "line1\nline2\n")
    parity("deep" => { "note" => "one\n\ntwo\n" })
    parity("stripped" => "no trailing newline")
  end

  it "family 5: Integer (and bool) keys ride plain" do
    parity(1 => "int")
    parity(true => "yes", 2.5 => "half")
  end

  it "round-trips under the compat loader" do
    objs = [
      { "z" => nil, "a" => [1, nil] }, { "inf" => Float::INFINITY },
      { "text" => "line1\nline2\n" }, { 1 => "int", "s" => "v" },
    ]
    objs.each do |o|
      expect(Yeptris::YAML.load(Yeptris::YAML.dump(o, header: true))).to eq(o)
    end
  end
end
