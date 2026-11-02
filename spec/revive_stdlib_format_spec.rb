# frozen_string_literal: true

# The audit fix (visitors.rb revive_object): stdlib Psych's !ruby/object
# format stores the instance state as the mapping's OWN top-level pairs
# (@-stripped by yaml_tree's dump_ivars), and !ruby/hash:K /
# !ruby/exception:K never dispatched at all. The old walk read only the
# __init__ marker (yeptris's own encoder format), so every stdlib
# Psych.dump-produced document revived empty.
#
# The stdlib EMITTED forms ride as literals — the byte shapes below are
# the yaml_tree output verified against the stdlib gem in a clean
# process (a runtime ::Psych.dump call would silently produce YEPTRIS
# format under the drop-in rebind, which other spec files load). The
# expected VALUES pin stdlib's revival semantics (psych 5.5 verified).
require "yeptris/psych"

# A plain class — no Encodable, no init_with: psych's ivar arm
class StdlibIvar
  def initialize
    @foo = 1
    @bar = "two"
  end
end

# A Hash subclass (yaml_tree visit_Hash: !ruby/hash:K)
class StdlibHashSub < Hash; end

# An Encodable class: the SAME class revives through BOTH formats —
# yeptris's __init__ marker (its own dumps) and psych's plain pairs
class StdlibEncodable
  include Yeptris::Psych::Encodable

  attr_accessor :one

  def init_with(coder)
    @one = coder["one"]
  end

  def encode_with(coder)
    coder["one"] = @one
  end

  def ==(other)
    one == other.one
  end
end

RSpec.describe "revival: stdlib Psych !ruby/ formats" do
  it "revives both ivars of a stdlib Psych.dump'd object" do
    # ::Psych.dump(StdlibIvar.new) in a clean stdlib process
    loaded = Yeptris::Psych.unsafe_load(<<~YAML)
      --- !ruby/object:StdlibIvar
      foo: 1
      bar: two
    YAML
    expect(loaded).to be_a(StdlibIvar)
    expect(loaded.instance_variable_get(:@foo)).to eq(1)
    expect(loaded.instance_variable_get(:@bar)).to eq("two")
  end

  it "revives the @-prefixed key spelling to the same ivars" do
    # yaml_tree strips @ when dumping; older psych and hand-written
    # docs spell the keys WITH it — both land on @foo
    loaded = Yeptris::Psych.unsafe_load(<<~YAML)
      --- !ruby/object:StdlibIvar
      "@foo": 42
      "@bar": pref
    YAML
    expect(loaded.instance_variable_get(:@foo)).to eq(42)
    expect(loaded.instance_variable_get(:@bar)).to eq("pref")
  end

  it "revives a stdlib-dumped bare Object with ivars" do
    # ::Psych.dump of an Object with @kept = :yes
    loaded = Yeptris::Psych.unsafe_load("--- !ruby/object\nkept: :yes\n")
    expect(loaded).to be_a(Object)
    expect(loaded.instance_variable_get(:@kept)).to eq(:yes)
  end

  it "revives nested state and keeps alias identity inside ivars" do
    loaded = Yeptris::Psych.unsafe_load(<<~YAML)
      --- !ruby/object:StdlibIvar
      foo:
      - 1
      - 2
      bar:
        a: &x shared
        b: *x
    YAML
    expect(loaded.instance_variable_get(:@foo)).to eq([1, 2])
    expect(loaded.instance_variable_get(:@bar)["a"]).to equal(loaded.instance_variable_get(:@bar)["b"])
  end

  it "dispatches !ruby/hash:K to the Hash subclass" do
    # ::Psych.dump(StdlibHashSub.new.merge("a" => 1, b: 2))
    loaded = Yeptris::Psych.unsafe_load(<<~YAML)
      --- !ruby/hash:StdlibHashSub
      a: 1
      :b: 2
    YAML
    expect(loaded).to be_a(StdlibHashSub)
    expect(loaded).to eq("a" => 1, b: 2)
  end

  it "raises stdlib's ArgumentError for a non-Hash subclass" do
    expect do
      Yeptris::Psych.unsafe_load("--- !ruby/hash:String\na: 1")
    end.to raise_error(ArgumentError, /expected a subclass of Hash, got String/)
  end

  it "revives a stdlib-dumped exception with message and ivars" do
    # ::Psych.dump of StandardError.new("boom") carrying @extra = 42;
    # the emitted backtrace pair is present-but-empty (stdlib's shape
    # for a never-set backtrace), consumed by the revival
    loaded = Yeptris::Psych.unsafe_load(<<~YAML)
      --- !ruby/exception:StandardError
      message: boom
      backtrace:
      extra: 42
    YAML
    expect(loaded).to be_a(StandardError)
    expect(loaded.message).to eq("boom")
    expect(loaded.instance_variable_get(:@extra)).to eq(42)
    expect(loaded.instance_variables).to eq([:@extra])
  end

  it "revives an exception with an explicit backtrace pair" do
    loaded = Yeptris::Psych.unsafe_load(<<~YAML)
      --- !ruby/exception:RuntimeError
      message: m
      backtrace:
      - a.rb:1
      extra: kept
    YAML
    expect(loaded).to be_a(RuntimeError)
    expect(loaded.message).to eq("m")
    expect(loaded.backtrace).to eq(["a.rb:1"])
    expect(loaded.instance_variable_get(:@extra)).to eq("kept")
  end

  it "revives a bare !ruby/exception as Exception" do
    loaded = Yeptris::Psych.unsafe_load("--- !ruby/exception\nmessage: bare\n")
    expect(loaded).to be_a(Exception)
    expect(loaded.message).to eq("bare")
  end

  it "revives a messageless exception (empty backtrace shape)" do
    loaded = Yeptris::Psych.unsafe_load(<<~YAML)
      --- !ruby/exception:StandardError
      backtrace:
    YAML
    expect(loaded).to be_a(StandardError)
    expect(loaded.message).to eq("StandardError")
  end

  it "routes a stdlib-format doc through init_with for Encodable classes" do
    # psych's format has no __init__ marker; a class defining
    # init_with takes the coder (raw pairs), exactly as stdlib does
    loaded = Yeptris::Psych.unsafe_load(<<~YAML)
      --- !ruby/object:StdlibEncodable
      one: 9
    YAML
    expect(loaded).to be_a(StdlibEncodable)
    expect(loaded.one).to eq(9)
  end

  it "keeps the yeptris __init__ format working for Encodable classes" do
    obj = StdlibEncodable.new
    obj.one = "yep"
    loaded = Yeptris::Psych.unsafe_load(Yeptris::Psych.dump(obj))
    expect(loaded).to be_a(StdlibEncodable)
    expect(loaded.one).to eq("yep")
  end

  it "keeps the DumpError gate for __init__-format non-Encodable classes" do
    # the pinned encapsulation rule: an __init__ doc claims the
    # protocol; a class that never opted in is refused
    yaml = "--- !ruby/object:StdlibIvar\n__init__: {}\n"
    expect { Yeptris::Psych.unsafe_load(yaml) }
      .to raise_error(Yeptris::DumpError, /Encodable/)
  end

  it "raises the same error type stdlib raises for an unknown class" do
    yaml = "--- !ruby/object:NoSuchClassAnywhere\nfoo: 1\n"
    # psych 5.5's safe face: "Tried to load unspecified class: X"
    # (verified in a clean stdlib process; the drop-in rebind other
    # spec files perform replaces the constant, so the shape is
    # pinned here as the literal)
    expect { Yeptris::Psych.load(yaml) }
      .to raise_error(Yeptris::Psych::DisallowedClass,
                      "Tried to load unspecified class: NoSuchClassAnywhere")
  end
end
