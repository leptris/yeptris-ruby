# frozen_string_literal: true

require "spec_helper"
require "psych" # stdlib first — the consumer scenario: its core_ext
# calls Psych.dump(self, options), which under the rebind resolves to
# OUR dump with the options hash in the io slot
require "yeptris/psych/drop_in"

# The #95 thread's third report: under the rebind, stdlib's
# Object#to_yaml (which calls Psych.dump(self, options)) crashed on
# our io-slot, and Psych::Visitors::YAMLTree.create was missing.
RSpec.describe "rebind surface: to_yaml and YAMLTree.create" do
  it "Hash#to_yaml dumps like Psych.dump" do
    expect({ "a" => 1, "b" => [1, 2] }.to_yaml).to eq(::Yeptris::Psych.dump("a" => 1, "b" => [1, 2]))
    expect({ "z" => nil }.to_yaml).to include("z:")
  end

  it "Array#to_yaml and scalar to_yaml work" do
    expect([1, "two"].to_yaml).to eq(::Yeptris::Psych.dump([1, "two"]))
    expect("hello".to_yaml).to eq("--- hello\n")
    expect(42.to_yaml).to eq("--- 42\n")
  end

  it "options in the stdlib positional slot are tolerated" do
    expect({ "a" => 1 }.to_yaml({})).to eq(::Yeptris::Psych.dump("a" => 1))
  end

  it "YAMLTree.create exists and produces a working tree" do
    tree = ::Yeptris::Psych::Visitors::YAMLTree.create
    expect(tree).to respond_to(:push)
    expect(tree).to respond_to(:finish)
    tree.push("a" => 1)
    expect(tree.finish).to eq("---\na: 1\n")
  end

  it "create with options and emitter positionals" do
    tree = ::Yeptris::Psych::Visitors::YAMLTree.create({}, nil)
    tree.push([1, nil])
    expect(tree.finish).to eq("---\n- 1\n-\n")
  end

  it "the stdlib << emitter face pushes" do
    tree = ::Yeptris::Psych::Visitors::YAMLTree.create({})
    tree << { "a" => 1 }
    expect(tree.finish).to eq("---\na: 1\n")
  end

  it "tree.yaml is stdlib dump's serialization tail" do
    tree = ::Yeptris::Psych::Visitors::YAMLTree.create({})
    tree << { "a" => [1, "two"] }
    expect(tree.tree.yaml).to eq(::Psych.dump("a" => [1, "two"]))

    io = StringIO.new
    expect(tree.tree.yaml(io)).to equal(io)
    expect(io.string).to eq(::Psych.dump("a" => [1, "two"]))
  end

  it "Psych.dump's stdlib two-arg Hash shape routes to options" do
    expect(::Psych.dump({ "a" => 1 }, {})).to eq("---\na: 1\n")
  end
end
