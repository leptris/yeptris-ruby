# frozen_string_literal: true

# #238's declared headroom, executed: :any keeps the resolver's
# verdict per value (typed Ruby objects, zero-copy strings), and
# first_wins: bounds a duplicate key's column to its first match
# within one mapping.
RSpec.describe "Yeptris::Schema :any + first_wins (#238 headroom)" do
  it "materializes typed values by the resolver's verdict" do
    desc = [
      { kind: :mapping, child_index: 1, child_count: 4 },
      { wire_name: "i", kind: :scalar, type: :any },
      { wire_name: "f", kind: :scalar, type: :any },
      { wire_name: "b", kind: :scalar, type: :any },
      { wire_name: "n", kind: :scalar, type: :any },
    ]
    out = Yeptris::Schema.load("i: 42\nf: 2.5\nb: true\nn: ~\n", desc: desc)
    expect(out[1]).to eq([42])
    expect(out[2]).to eq([2.5])
    expect(out[3]).to eq([true])
    expect(out[4]).to eq([nil])
  end

  it "keeps strings zero-copy and carries the compat verdicts" do
    desc = [
      { kind: :mapping, child_index: 1, child_count: 2 },
      { wire_name: "s", kind: :scalar, type: :any },
      { wire_name: "on", kind: :scalar, type: :any },
    ]
    out = Yeptris::Schema.load("s: word\non: yes\n", desc: desc, schema: :compat_11)
    expect(out[1]).to eq(["word"])
    expect(out[2]).to eq([true]) # compat: y/n/yes/no/on/off are bools
  end

  it "bounds duplicates to the first match within one mapping" do
    desc = [
      { kind: :mapping, child_index: 1, child_count: 2 },
      { wire_name: "k", kind: :scalar, type: :str, first_wins: true },
      { wire_name: "v", kind: :scalar, type: :str },
    ]
    out = Yeptris::Schema.load("k: first\nv: 1\nk: second\nv: 2\n", desc: desc)
    expect(out[1]).to eq(["first"])
    expect(out[2]).to eq(["1", "2"]) # default keeps both
  end

  it "scopes first_wins to one mapping instance" do
    desc = [
      { kind: :sequence, child_index: 1, child_count: 1 },
      { kind: :scalar, type: :str, first_wins: true },
    ]
    out = Yeptris::Schema.load("- a\n- b\n", desc: desc)
    expect(out[1]).to eq(["a", "b"]) # different elements: both land
  end
end
