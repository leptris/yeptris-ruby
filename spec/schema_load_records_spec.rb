# frozen_string_literal: true

require "spec_helper"

# #184: the lutaml-model KV recipe — Schema columns → record hashes
# ready for Serializable.instantiate.
RSpec.describe Yeptris::Schema, ".load_records" do
  before { skip "schema headroom needs C >= 0.6.13" unless Yeptris::Schema.headroom_supported? }

  it "zips a mapping root into one kwargs hash" do
    desc = [
      { kind: :mapping, child_index: 1, child_count: 3 },
      { wire_name: "id", kind: :scalar, type: :int },
      { wire_name: "name", kind: :scalar, type: :str },
      { wire_name: "active", kind: :scalar, type: :bool },
    ]
    rows = Yeptris::Schema.load_records("id: 42\nname: widget\nactive: true\n", desc: desc)
    expect(rows).to eq([{ id: 42, name: "widget", active: true }])
  end

  it "zips a sequence-of-mappings into N kwargs hashes" do
    desc = [
      { kind: :sequence, child_index: 1, child_count: 1 },
      { kind: :mapping, child_index: 2, child_count: 2 },
      { wire_name: "id", kind: :scalar, type: :int },
      { wire_name: "name", kind: :scalar, type: :str },
    ]
    src = "- id: 1\n  name: a\n- id: 2\n  name: b\n"
    rows = Yeptris::Schema.load_records(src, desc: desc)
    expect(rows).to eq([{ id: 1, name: "a" }, { id: 2, name: "b" }])
  end

  it "keeps sequence-of-scalars as :value hashes" do
    desc = [
      { kind: :sequence, child_index: 1, child_count: 1 },
      { kind: :scalar, type: :int },
    ]
    rows = Yeptris::Schema.load_records("- 1\n- 2\n- 3\n", desc: desc)
    expect(rows).to eq([{ value: 1 }, { value: 2 }, { value: 3 }])
  end

  # lutaml-model's load-bearing edge: ABSENT keys are OMITTED from the
  # hash (not nil-filled) — absent seeds defaults + using_default?;
  # explicit nil is a present value with different render semantics.
  it "omits absent keys (does not nil-fill)" do
    desc = [
      { kind: :mapping, child_index: 1, child_count: 3 },
      { wire_name: "id", kind: :scalar, type: :int },
      { wire_name: "name", kind: :scalar, type: :any },
      { wire_name: "note", kind: :scalar, type: :str },
    ]
    # 'note' absent from the source; 'name' explicitly null (:any gives
    # the resolver's verdict: nil for a null scalar)
    rows = Yeptris::Schema.load_records("id: 7\nname: null\n", desc: desc)
    expect(rows[0]).to eq({ id: 7, name: nil }) # note: OMITTED
    expect(rows[0]).not_to have_key(:note)
  end

  it "per-row absence in sequence-of-mappings" do
    desc = [
      { kind: :sequence, child_index: 1, child_count: 1 },
      { kind: :mapping, child_index: 2, child_count: 2 },
      { wire_name: "id", kind: :scalar, type: :int },
      { wire_name: "tag", kind: :scalar, type: :str },
    ]
    # row 2 lacks 'tag'
    rows = Yeptris::Schema.load_records("- id: 1\n  tag: x\n- id: 2\n", desc: desc)
    expect(rows[0]).to eq({ id: 1, tag: "x" })
    expect(rows[1]).to eq({ id: 2 }) # tag: omitted
    expect(rows[1]).not_to have_key(:tag)
  end

  # sequence-of-scalars under the C schema ABI: the elements drain
  # into the sequence's own column but the kv path's flat records
  # don't exercise it yet — tracked with #179's Schema feature work
  xit "handles collections (the doc-ask example)"
end
