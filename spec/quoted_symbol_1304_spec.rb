# frozen_string_literal: true

# yeptris#1304: the quoted-symbol literal keeps its quotes. The plain
# scalar `:"x y"` names the UNQUOTED string (psych's scan_symbol law:
# the quoted form is the quoting AROUND the name, not part of it) —
# yeptris handed the QUOTED spelling to the symbol resolver, so every
# materialization face produced :"\"x y\"". Single-quoted symbol
# literals (`:'q z'`) ride the same law; escape sequences do NOT
# decode (the literal is a plain scalar — psych's scanner captures the
# inner text verbatim).

RSpec.describe "quoted-symbol literal strip (#1304)" do
  # psych's own scanner law (scalar_scanner tokenize, the /^:/ arm):
  # /^:(["'])(.*)\1/ strips the leading colon AND the matching quote
  # pair; the bare form strips only the colon.
  DOUBLE = "a: :\"x y\"\n"
  SINGLE = "b: :'q z'\n"
  KEYED  = ":\"quoted key\": 1\n"

  it "loads the double-quoted symbol value bare (safe_load)" do
    expect(Yeptris::YAML.safe_load(DOUBLE, permitted_classes: [Symbol]))
      .to eq("a" => :"x y")
  end

  it "loads the single-quoted symbol value bare (safe_load)" do
    expect(Yeptris::YAML.safe_load(SINGLE, permitted_classes: [Symbol]))
      .to eq("b" => :"q z")
  end

  it "loads the quoted symbol on the drain path (YAML.load)" do
    expect(Yeptris::YAML.load(DOUBLE)).to eq("a" => :"x y")
    expect(Yeptris::YAML.load(SINGLE)).to eq("b" => :"q z")
  end

  it "names the quoted-symbol KEY bare" do
    expect(Yeptris::YAML.load(KEYED)).to eq(:"quoted key" => 1)
    expect(Yeptris::YAML.safe_load(KEYED, permitted_classes: [Symbol]))
      .to eq(:"quoted key" => 1)
  end

  it "resolves through the DOM walk (node API, marshal lane refused)" do
    doc = Yeptris::Document.parse(DOUBLE, schema: :compat_11)
    expect(doc.root(0).to_ruby).to eq("a" => :"x y")
    doc.free
  end

  it "resolves through the stream iterator (each_document)" do
    docs = []
    Yeptris::YAML.each_document(DOUBLE) { |d| docs << d }
    expect(docs).to eq(["a" => :"x y"])
  end

  it "keeps the marshal fast lane refused for quoted-symbol sources" do
    # the C marshal builder names the symbol from the raw scalar text
    # (engine finding: marshal.c e_sym strips the colon but not the
    # quotes) — the binding must refuse the lane and walk in Ruby,
    # where the strip law lives, until the engine strip lands
    doc = Yeptris::Document.parse(DOUBLE, schema: :compat_11)
    expect(doc.root(0).marshal_fast).to be_nil
    doc.free
  end

  it "does not decode escapes (the literal is a plain scalar)" do
    # psych verbatim: the quoted-symbol capture keeps the inner text
    # byte for byte — "\t" stays backslash-t
    res = Yeptris::YAML.safe_load("c: :\"a\\tb\"\n", permitted_classes: [Symbol])
    expect(res).to eq("c" => :"a\\tb")
  end

  it "matches stdlib psych on the quoted-symbol matrix" do
    require "yaml"
    [DOUBLE, SINGLE, KEYED].each do |src|
      psych = ::Psych.safe_load(src, permitted_classes: [Symbol])
      yep = Yeptris::YAML.safe_load(src, permitted_classes: [Symbol])
      expect(yep).to eq(psych)
    end
  end

  it "leaves unquoted and namespace-colon forms untouched" do
    # the pre-existing law: plain :name strips the colon, ::name is a
    # String (the namespace guard), quoting decides nothing else
    res = Yeptris::YAML.load("p: :plain\nn: ::const\n")
    expect(res).to eq("p" => :plain, "n" => "::const")
  end
end
