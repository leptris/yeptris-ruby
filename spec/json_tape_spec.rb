# frozen_string_literal: true

# The public columnar tape face (yeptris-ruby#411): ONE fused parse
# per document, records exposed as typed columns — no Ruby tree.
# Yeptris::JSON.load already rides this engine internally; the face
# hands the columnar data to the caller.
RSpec.describe Yeptris::JSON::Tape do
  describe ".parse" do
    it "counts one record per token" do
      tape = described_class.parse('{"a":[1,2],"b":"x"}')

      expect(tape.count).to be_positive
      tape.free
    end

    it "classifies record kinds" do
      tape = described_class.parse('[null, true, false, 7, 1.5, "s"]')
      kinds = tape.kinds

      expect(kinds).to include(:seq_open, :close)
      expect(kinds).to include(:null, :true, :false, :int, :float, :str)
      tape.free
    end

    it "exposes zero-copy spans decoded on the Ruby side" do
      src = '{"b":"xy"}'
      tape = described_class.parse(src)
      # two STR records — the map key and the value; the value is last
      i = tape.kinds.rindex(:str)

      off, len = tape.span(i)
      expect(tape.value(i)).to eq("xy")
      # the span indexes the caller's bytes (zero-copy contract; the
      # quotes sit outside the span)
      expect(src.byteslice(off, len)).to eq("xy")
      tape.free
    end

    it "materializes scalar values per record" do
      tape = described_class.parse('{"a":[1,-2],"b":3.5,"c":null,"d":true,"e":false}')

      values = tape.kinds.each_index.map { |i| tape.value(i) }
      expect(values).to include(1, -2, 3.5, nil, true, false)
      expect(values).to include("a", "b", "c", "d", "e")
      tape.free
    end

    it "links containers to their matching close" do
      tape = described_class.parse('{"a":[1,2]}')
      i = tape.kinds.index(:map_open)

      close = tape.match(i)
      expect(tape.kinds[close]).to eq(:close)
      seq = tape.kinds.index(:seq_open)
      expect(tape.kinds[tape.match(seq)]).to eq(:close)
      tape.free
    end

    it "rejects invalid JSON with the engine's error detail" do
      expect { described_class.parse('{"a": [1, 2') }
        .to raise_error(Yeptris::JSON::ParseError)
    end

    it "parses with the lenient route on request (deferred numbers)" do
      tape = described_class.parse("[1.2.3]", lenient: true)

      expect(tape.kinds).to include(:num)
      tape.free
    end

    it "keeps the source alive for the tape's spans (the borrow law)" do
      tape = described_class.parse('{"k":"v"}')
      GC.start
      i = tape.kinds.rindex(:str)

      expect(tape.value(i)).to eq("v")
      tape.free
    end

    it "walks a compiled plan over the tape" do
      plan = Yeptris::Plan.compile(
        { "kind" => "map", "path" => "items",
          "children" => [{ "name" => "id", "kind" => "int" }] }.to_json
      )
      tape = described_class.parse('{"items":[{"id":1},{"id":2}]}')

      result = tape.plan_walk(plan)
      expect(result.ints(0)).to eq([1, 2])

      result.free
      plan.free
      tape.free
    end
  end
end
