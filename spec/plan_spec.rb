# frozen_string_literal: true

require "json"

# The plan face (yeptris-ruby#411; the rs `pub mod plan` parity
# surface): compile a strict-JSON plan spec once, apply it to a
# document (DOM leg) or a JSON tape (tape leg), read typed columns.
# The Descriptor classes stay the lutaml-vocabulary layer; Plan is
# the cross-runtime face the "query" benchmark op rides.
RSpec.describe Yeptris::Plan do
  let(:spec) do
    {
      "kind" => "seq",
      "children" => [
        { "name" => "id", "kind" => "int" },
        { "name" => "name", "kind" => "str" },
        { "name" => "ok", "kind" => "bool" },
        { "name" => "score", "kind" => "float" },
      ],
    }.to_json
  end

  describe ".compile" do
    it "compiles a spec string and reports the column count" do
      plan = described_class.compile(spec)

      expect(plan.column_count).to eq(4)
      plan.free
    end

    it "accepts a segmented path spec (the rows live under path)" do
      plan = described_class.compile(
        { "kind" => "map", "path" => %w[data items],
          "children" => [{ "name" => "id", "kind" => "int" }] }.to_json
      )

      expect(plan.column_count).to eq(1)
      plan.free
    end

    it "raises Plan::Error on a malformed spec" do
      expect { described_class.compile("{not json") }
        .to raise_error(Yeptris::Plan::Error)
    end

    it "raises Plan::Error on an unknown leaf kind" do
      expect do
        described_class.compile(
          { "kind" => "seq", "children" => [{ "name" => "x", "kind" => "blob" }] }.to_json
        )
      end.to raise_error(Yeptris::Plan::Error)
    end
  end

  describe "the DOM leg (Document#plan_walk)" do
    let(:yaml) do
      <<~YAML
        - id: 1
          name: a
          ok: true
          score: 1.5
        - id: 2
          name: b
          ok: false
          score: 2.5
      YAML
    end

    it "walks a parsed document into typed columns" do
      plan = described_class.compile(spec)
      doc = Yeptris::Document.parse(yaml)

      result = doc.plan_walk(plan)

      expect(result.rows).to eq(2)
      expect(result.column_kind(0)).to eq(:int)
      expect(result.column_kind(1)).to eq(:str)
      expect(result.column_kind(2)).to eq(:bool)
      expect(result.column_kind(3)).to eq(:float)
      expect(result.ints(0)).to eq([1, 2])
      expect(result.strs(1)).to eq(%w[a b])
      expect(result.bools(2)).to eq([true, false])
      expect(result.floats(3)).to eq([1.5, 2.5])
      expect(result.nulls(0)).to eq([false, false])

      result.free
      plan.free
      doc.free
    end

    it "marks missing leaves null" do
      plan = described_class.compile(
        { "kind" => "seq",
          "children" => [{ "name" => "id", "kind" => "int" },
                         { "name" => "ghost", "kind" => "str" }] }.to_json
      )
      doc = Yeptris::Document.parse("- id: 7\n- id: 8\n  ghost: g\n")

      result = doc.plan_walk(plan)

      expect(result.rows).to eq(2)
      expect(result.ints(0)).to eq([7, 8])
      expect(result.strs(1)).to eq([nil, "g"])
      expect(result.nulls(1)).to eq([true, false])

      result.free
      plan.free
      doc.free
    end

    it "raises Plan::Error when the document shape disagrees" do
      plan = described_class.compile(
        { "kind" => "map", "path" => "rows",
          "children" => [{ "name" => "id", "kind" => "int" }] }.to_json
      )
      doc = Yeptris::Document.parse("- just a scalar seq\n")

      expect { doc.plan_walk(plan) }.to raise_error(Yeptris::Plan::Error)

      plan.free
      doc.free
    end
  end

  describe "the tape leg (Yeptris::JSON::Tape#plan_walk)" do
    it "walks a parsed tape into typed columns" do
      plan = described_class.compile(
        { "kind" => "map", "path" => "items",
          "children" => [{ "name" => "id", "kind" => "int" },
                         { "name" => "name", "kind" => "str" }] }.to_json
      )
      json = '{"items":[{"id":1,"name":"a"},{"id":2,"name":"b"}]}'
      tape = Yeptris::JSON::Tape.parse(json)

      result = tape.plan_walk(plan)

      expect(result.rows).to eq(2)
      expect(result.ints(0)).to eq([1, 2])
      expect(result.strs(1)).to eq(%w[a b])

      result.free
      plan.free
      tape.free
    end
  end
end
