# frozen_string_literal: true

# Ports of the loading-semantics subset of psych/test/psych/*.rb
# (test_nil, test_merge_keys, test_alias_and_anchor, test_array,
# test_hash, test_date_time, test_string — the cases that exercise
# load/dump of plain data). Object-serialization cases (ruby/object
# tags, custom classes, ivars) wait for the Yeptris::Psych namespace
# and YAMLTree (phase C); exclusions are marked inline.

RSpec.describe "Psych port: nil" do
  it "round-trips nil" do
    expect(Yeptris::YAML.load(Yeptris::YAML.dump(nil))).to be_nil
  end

  it "round-trips [nil]" do
    yml = Yeptris::YAML.dump([nil])
    expect(Yeptris::YAML.load(yml)).to eq([nil])
  end
end

RSpec.describe "Psych port: merge keys" do
  it "merges a bare hash" do
    doc = Yeptris::YAML.parse_yaml(<<~YAML)
      map:
        <<:
          hello: world
    YAML
    expect(doc).to eq("map" => { "hello" => "world" })
  end

  it "existing keys win over merged keys" do
    doc = Yeptris::YAML.parse_yaml(<<~YAML)
      base: &b
        a: 1
        b: 2
      derived:
        <<: *b
        b: 20
    YAML
    expect(doc["derived"]).to eq("a" => 1, "b" => 20)
  end

  it "merges arrays of maps in order (earlier wins)" do
    doc = Yeptris::YAML.parse_yaml(<<~YAML)
      first: &first
        a: 1
        c: 3
      second: &second
        a: 10
        d: 4
      merged:
        <<: [*first, *second]
    YAML
    expect(doc["merged"]).to eq("a" => 1, "c" => 3, "d" => 4)
  end
end

RSpec.describe "Psych port: aliases and anchors" do
  it "aliases resolve to the same object" do
    doc = Yeptris::YAML.parse_yaml(<<~YAML)
      ---
      - &id001
        a: 1
      - *id001
      - *id001
    YAML
    expect(doc[1]).to equal(doc[0])
    expect(doc[2]).to equal(doc[0])
  end

  it "aliases to scalars carry the value" do
    doc = Yeptris::YAML.parse_yaml(<<~YAML)
      name: &n yeptris
      same: *n
    YAML
    expect(doc["same"]).to eq("yeptris")
  end
end

RSpec.describe "Psych port: arrays and hashes" do
  it "round-trips nested arrays" do
    x = [[1, 2], ["a", ["b"]], []]
    expect(Yeptris::YAML.load(Yeptris::YAML.dump(x))).to eq(x)
  end

  it "round-trips nested hashes" do
    x = { "a" => { "b" => { "c" => 1 } }, "d" => {} }
    expect(Yeptris::YAML.load(Yeptris::YAML.dump(x))).to eq(x)
  end

  it "round-trips mixed structures" do
    x = { "list" => [1, 2.5, true, nil, "s"], "map" => { "x" => [nil] } }
    expect(Yeptris::YAML.load(Yeptris::YAML.dump(x))).to eq(x)
  end

  it "round-trips symbol keys and values" do
    x = { a: :b, c: [1, :two] }
    expect(Yeptris::YAML.load(Yeptris::YAML.dump(x))).to eq(x)
  end
end

RSpec.describe "Psych port: date and time" do
  it "loads a date as Date" do
    expect(Yeptris::YAML.load("d: 2017-04-13")).to eq("d" => Date.new(2017, 4, 13))
  end

  it "loads a timestamp with zone as Time" do
    t = Yeptris::YAML.load("t: 2017-04-13 12:00:00.5 +09:00")["t"]
    expect(t).to be_a(Time)
    expect(t.to_i).to eq(Time.utc(2017, 4, 13, 3, 0, 0).to_i)
  end

  it "round-trips a date through dump" do
    expect(Yeptris::YAML.load(Yeptris::YAML.dump(Date.new(2017, 4, 13))))
      .to eq(Date.new(2017, 4, 13))
  end
end

RSpec.describe "Psych port: strings" do
  it "plain strings stay plain" do
    expect(Yeptris::YAML.load("s: hello")).to eq("s" => "hello")
  end

  it "numeric-looking strings are quoted on dump and reload as strings" do
    expect(Yeptris::YAML.load(Yeptris::YAML.dump("12"))).to eq("12")
    expect(Yeptris::YAML.load(Yeptris::YAML.dump("true"))).to eq("true")
    expect(Yeptris::YAML.load(Yeptris::YAML.dump("~"))).to eq("~")
  end

  it "quoted strings always load as strings" do
    expect(Yeptris::YAML.load('a: "12"')).to eq("a" => "12")
    expect(Yeptris::YAML.load("a: 'yes'")).to eq("a" => "yes")
  end

  it "multibyte strings round-trip" do
    x = "こんにちは yeptris"
    expect(Yeptris::YAML.load(Yeptris::YAML.dump(x))).to eq(x)
  end

  it "strings with newlines round-trip" do
    x = "line one\nline two\n"
    expect(Yeptris::YAML.load(Yeptris::YAML.dump(x))).to eq(x)
  end

  it "empty strings round-trip" do
    expect(Yeptris::YAML.load(Yeptris::YAML.dump(""))).to eq("")
  end
end

RSpec.describe "Psych port: merge keys are tag-driven" do
  it "merges a plain << but keeps a quoted '<<' literal" do
    expect(Yeptris::YAML.load("a: 1\n<<: {b: 2}\n")).to eq("a" => 1, "b" => 2)
    expect(Yeptris::YAML.load("a: 1\n'<<': {b: 2}\n")).to eq("a" => 1, "<<" => {"b" => 2})
    expect(Yeptris::YAML.load("a: 1\n\"<<\": {b: 2}\n")).to eq("a" => 1, "<<" => {"b" => 2})
  end
end
