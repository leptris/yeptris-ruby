# frozen_string_literal: true

# The schema-descriptor binding (issue #73 / C issue #238): the
# consumer-shaped plan from the reporter's spike — root mapping ->
# "item" sequence -> element mapping -> id INT / name STR / tags
# SEQUENCE of STR — materialized from both YAML and strict JSON.
RSpec.describe "Yeptris::Schema.load" do
  # flat descriptor, ABI 1:1 (child slices positional)
  DESC = [
    { wire_name: nil, kind: :mapping, child_index: 1, child_count: 1 },
    { wire_name: "item", kind: :sequence, child_index: 2 },
    { wire_name: nil, kind: :mapping, child_index: 3, child_count: 3 },
    { wire_name: "id", kind: :scalar, type: :int },
    { wire_name: "name", kind: :scalar, type: :str },
    { wire_name: "tags", kind: :sequence, child_index: 6 },
    { wire_name: nil, kind: :scalar, type: :str }
  ].freeze

  YAML_DOC = <<~YAML
    item:
      - id: 1
        name: alpha
        tags: [x, y]
      - id: 2
        name: beta
        tags: [z]
  YAML
  JSON_DOC = '{"item":[{"id":3,"name":"gamma","tags":["p","q","r"]}]}'

  it "materializes typed columns from YAML in one native pass" do
    cols = Yeptris::Schema.load(YAML_DOC, schema: :compat_11, desc: DESC)
    expect(cols[3]).to eq([1, 2])                # id INT
    expect(cols[4]).to eq(%w[alpha beta])        # name STR
    expect(cols[6]).to eq(%w[x y z])             # tags SEQ of STR (doc order)
  end

  it "takes strict JSON through the same door" do
    cols = Yeptris::Schema.load(JSON_DOC, desc: DESC)
    expect(cols[3]).to eq([3])
    expect(cols[4]).to eq(["gamma"])
    expect(cols[6]).to eq(%w[p q r])
  end

  it "raises RequiredMissing naming the node" do
    desc = [
      { wire_name: nil, kind: :mapping, child_index: 1, child_count: 1 },
      { wire_name: "must", kind: :scalar, type: :int, required: true }
    ]
    expect { Yeptris::Schema.load("other: 1\n", desc: desc) }
      .to raise_error(Yeptris::Schema::RequiredMissing, /node 1/)
  end

  it "returns zero-copy spans for CALLBACK plans" do
    desc = [
      { wire_name: nil, kind: :mapping, child_index: 1, child_count: 1 },
      { wire_name: "custom", kind: :callback }
    ]
    cols = Yeptris::Schema.load("custom: 12:34:56\n", desc: desc)
    expect(cols[1].length).to eq(1)
    expect(cols[1][0].bytes_from("custom: 12:34:56\n")).to eq("12:34:56")
  end
end

RSpec.describe "safe_load error naming (issue #73)" do
  it "exposes the classes at the Yeptris:: level" do
    expect(Yeptris::DisallowedClass).to equal(Yeptris::Psych::DisallowedClass)
    expect(Yeptris::AliasesError).to equal(Yeptris::Psych::AliasesError)
    expect { Yeptris::YAML.safe_load("a: &x 1\nb: *x\n") }
      .to raise_error(Yeptris::AliasesError)
  end
end
