# frozen_string_literal: true

RSpec.describe "Yeptris::Psych drop-in" do
  before(:all) { require "yeptris/psych/drop_in" }

  it "rebinds the top-level Psych constant" do
    expect(::Psych).to equal(Yeptris::Psych)
  end

  it "loads plain data safely by default (Psych 5 semantics)" do
    expect(Psych.load("a: 1\nb: [x, ~]\n")).to eq("a" => 1, "b" => ["x", nil])
  end

  it "raises DisallowedClass on non-core tags" do
    expect { Psych.load("a: !ruby/object:Object\n  x: 1\n") }
      .to raise_error(Psych::DisallowedClass, /Object/)
  end

  it "raises AliasNotEnabled unless aliases are opted in" do
    expect { Psych.load("a: &x 1\nb: *x\n") }
      .to raise_error(Psych::AliasNotEnabled)
    expect(Psych.load("a: &x 1\nb: *x\n", aliases: true)).to eq("a" => 1, "b" => 1)
  end

  it "unsafe_load materializes without checks" do
    expect(Psych.unsafe_load("a: &x 1\nb: *x\n")).to eq("a" => 1, "b" => 1)
  end

  it "wraps parse failures in Psych::SyntaxError" do
    expect { Psych.parse("a: [1,") }.to raise_error(Psych::SyntaxError)
  end

  it "parse returns the Nodes tree without materializing" do
    tree = Psych.parse("name: yeptris\nlist:\n  - 1\n  - two\n")
    expect(tree).to be_a(Psych::Nodes::Document)
    mapping = tree.children.first
    expect(mapping).to be_a(Psych::Nodes::Mapping)
    expect(mapping.children[0].value).to eq("name")
    expect(mapping.children[2].value).to eq("list")
    seq = mapping.children[3]
    expect(seq).to be_a(Psych::Nodes::Sequence)
    expect(seq.children.size).to eq(2)
    # to_ruby works off the tree (document stays alive with it)
    expect(tree.children.first.to_ruby)
      .to eq("name" => "yeptris", "list" => [1, "two"])
  end

  it "parse_stream walks every document" do
    stream = Psych.parse_stream("--- 1\n--- 2\n")
    expect(stream.children.size).to eq(2)
    expect(stream.children.map { |d| d.children.first.to_ruby }).to eq([1, 2])
  end

  it "dump writes through the yeptris builder" do
    expect(Psych.dump("a" => 1)).to eq("a: 1\n")
  end
end

RSpec.describe "readonly documents" do
  it "memoizes materialization per node" do
    doc = Yeptris::Document.parse("a: &x {k: 1}\nb: *x\nc: *x\n").readonly!
    root = doc.root
    first = root.to_ruby
    again = root.to_ruby
    expect(again).to equal(first) # the whole tree, one walk
    obj = first
    expect(obj["b"]).to equal(obj["c"])
    expect(obj["b"]).to equal(obj["a"]) # aliases all one object
  end
end

RSpec.describe "Yeptris::Psych co-existence (issue #69)" do
  lib = File.expand_path("../lib", __dir__)

  ours_first = <<~RUBY
    require "yeptris"
    require "yeptris/psych"
    require "psych" # stdlib AFTER ours: the order that clobbered pre-#69
    raise "rebound!" if ::Psych.equal?(Yeptris::Psych)
    raise "stdlib broken" unless ::Psych.load("a: 1") == { "a" => 1 }
    raise "ours broken" unless Yeptris::Psych.load("a: 1") == { "a" => 1 }
  RUBY

  stdlib_first = <<~RUBY
    require "psych"
    require "yeptris"
    require "yeptris/psych" # ours AFTER stdlib: the other clobbered order
    raise "rebound!" if ::Psych.equal?(Yeptris::Psych)
    raise "stdlib broken" unless ::Psych.load("a: 1") == { "a" => 1 }
    raise "ours broken" unless Yeptris::Psych.load("a: 1") == { "a" => 1 }
  RUBY

  drop_in_check = <<~RUBY
    require "yeptris/psych/drop_in"
    raise "not rebound" unless ::Psych.equal?(Yeptris::Psych)
    raise "load broken" unless Psych.load("a: 1") == { "a" => 1 }
  RUBY

  def run_script(lib, code)
    system(Gem.ruby, "-I", lib, "-e", code)
  end

  it "coexists when stdlib psych loads AFTER yeptris/psych" do
    expect(run_script(lib, ours_first)).to be(true)
  end

  it "coexists when stdlib psych loads FIRST" do
    expect(run_script(lib, stdlib_first)).to be(true)
  end

  it "still rebinds when the drop-in is explicitly requested" do
    expect(run_script(lib, drop_in_check)).to be(true)
  end
end

RSpec.describe "Yeptris::YAML.safe_load (issue #69)" do
  it "permits plain data by default and rejects non-permitted classes" do
    expect(Yeptris::YAML.safe_load("a: 1\nb: [x, ~]\n")).to eq("a" => 1, "b" => ["x", nil])
    expect { Yeptris::YAML.safe_load("d: 2020-01-02\n") }
      .to raise_error(Yeptris::Psych::DisallowedClass, /Date/)
    expect(Yeptris::YAML.safe_load("d: 2020-01-02\n", permitted_classes: [Date]))
      .to eq("d" => Date.new(2020, 1, 2))
  end

  it "rejects aliases unless allowed" do
    expect { Yeptris::YAML.safe_load("a: &x 1\nb: *x\n") }
      .to raise_error(Yeptris::Psych::AliasesError)
    expect(Yeptris::YAML.safe_load("a: &x 1\nb: *x\n", aliases: true)).to eq("a" => 1, "b" => 1)
  end
end
