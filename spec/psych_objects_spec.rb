# frozen_string_literal: true

# Ports of psych's object-serialization half (test_object.rb,
# test_coder.rb, test_struct.rb, test_set.rb, test_merge_keys
# object cases) against the Yeptris::Psych drop-in.

class Foo
  attr_accessor :one, :two, :three

  def initialize(one, two, three)
    @one = one
    @two = two
    @three = three
  end

  def ==(other)
    one == other.one && two == other.two && three == other.three
  end
end

class CoderObject
  attr_accessor :name, :value

  def init_with(coder)
    @name = coder["name"]
    @value = coder["value"]
  end

  def encode_with(coder)
    coder["name"] = @name
    coder["value"] = @value
  end
end

RSpec.describe "Psych port: objects" do
  before(:all) { require "yeptris/psych" }

  it "round-trips an ivar-carrying object (!ruby/object)" do
    foo = Foo.new("a", 1, true)
    loaded = Psych.unsafe_load(Psych.dump(foo))
    expect(loaded).to be_a(Foo)
    expect(loaded.one).to eq("a")
    expect(loaded.two).to eq(1)
    expect(loaded.three).to be(true)
  end

  it "round-trips encode_with / init_with" do
    obj = CoderObject.new
    obj.name = "hello"
    obj.value = 42
    loaded = Psych.unsafe_load(Psych.dump(obj))
    expect(loaded).to be_a(CoderObject)
    expect(loaded.name).to eq("hello")
    expect(loaded.value).to eq(42)
  end

  it "emits the !ruby/object tag" do
    expect(Psych.dump(Foo.new(1, 2, 3))).to include("!ruby/object:Foo")
  end

  it "preserves shared-object identity through aliases" do
    shared = Foo.new("s", 0, nil)
    holder = { "a" => shared, "b" => shared }
    loaded = Psych.unsafe_load(Psych.dump(holder))
    expect(loaded["a"]).to equal(loaded["b"])
  end

  it "handles self-referencing structures" do
    arr = []
    arr << arr
    loaded = Psych.unsafe_load(Psych.dump(arr))
    expect(loaded[0]).to equal(loaded)
  end

  it "round-trips a nested object graph" do
    inner = Foo.new(:sym, 2.5, [1, 2])
    outer = Foo.new(inner, { "x" => inner }, nil)
    loaded = Psych.unsafe_load(Psych.dump(outer))
    expect(loaded.one.one).to eq(:sym)
    expect(loaded.two["x"]).to equal(loaded.one)
  end
end

RSpec.describe "Psych port: structs and sets" do
  before(:all) { require "yeptris/psych" }

  it "round-trips a Struct" do
    Struct.new("Point2", :x, :y) unless Struct.const_defined?(:Point2)
    pt = Struct::Point2.new(3, 4)
    loaded = Psych.unsafe_load(Psych.dump(pt))
    expect(loaded).to be_a(Struct::Point2)
    expect(loaded.x).to eq(3)
    expect(loaded.y).to eq(4)
  end

  it "round-trips an anonymous-struct shape" do
    pt = Struct.new(:a, :b).new(1, 2)
    loaded = Psych.unsafe_load(Psych.dump(pt))
    expect(loaded.a).to eq(1)
    expect(loaded.b).to eq(2)
  end

  it "round-trips a Set" do
    set = Set.new([1, "two", :three])
    loaded = Psych.unsafe_load(Psych.dump(set))
    expect(loaded).to be_a(Set)
    expect(loaded.to_a).to contain_exactly(1, "two", :three)
  end

  it "round-trips an empty object" do
    obj = Object.new
    loaded = Psych.unsafe_load(Psych.dump(obj))
    expect(loaded).to be_a(Object)
    expect(loaded.instance_variables).to be_empty
  end

  it "round-trips Date and Time inside objects" do
    obj = Foo.new(Date.new(2026, 9, 3), Time.utc(2020, 1, 2, 3), nil)
    loaded = Psych.unsafe_load(Psych.dump(obj))
    expect(loaded.one).to eq(Date.new(2026, 9, 3))
    expect(loaded.two).to eq(Time.utc(2020, 1, 2, 3))
  end
end
