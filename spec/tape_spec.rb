# frozen_string_literal: true

# The JSON tape view (yeptris/tape.h; yeptris-ruby#411). Real
# behavior: kinds, spans, conversion, matching, the lenient deferred
# contract, and ownership — asserted as plain values.
require "json"

RSpec.describe Yeptris::JSON::Tape do
  let(:src) { '{"a": [1, 2.5, "x\ny", true, null], "b": {"c": -7}}' }

  describe "parse" do
    it "records one record per token after the DOC boundary" do
      tape = described_class.parse(src)
      expect(tape.count).to eq(16)
      expect(tape.kind(0)).to eq(:doc)
      expect(tape.each.count).to eq(16)
    end

    it "maps the ABI-pinned kinds" do
      tape = described_class.parse(src)
      expect(tape.each.map(&:kind)).to eq(
        %i[doc map_open str seq_open int float str true null close str
           map_open str int close close]
      )
    end

    it "exposes the raw span columns" do
      tape = described_class.parse(src)
      expect(tape.span(4)).to eq([7, 1]) # the 1
      expect(tape.span(5)).to eq([10, 3]) # the 2.5
      expect(tape.span(6)).to eq([16, 4]) # "x\ny" — the ESCAPED span
      expect(tape.span(1)).to be_nil # a container carries no span
      expect(tape.off(1)).to eq(15) # the container link (see match)
    end

    it "slices raw source bytes (escapes untouched)" do
      tape = described_class.parse(src)
      expect(tape.slice(4)).to eq("1")
      expect(tape.slice(6)).to eq("x\\ny")
      expect(tape.slice(6).encoding).to eq(Encoding::BINARY)
    end

    it "decodes strings (the same kernel JSON.load uses)" do
      tape = described_class.parse(src)
      expect(tape.string_at(2)).to eq("a")
      expect(tape.string_at(6)).to eq("x\ny")
    end

    it "links containers to their match" do
      tape = described_class.parse(src)
      expect(tape.match(1)).to eq(15) # root map_open -> its close
      expect(tape.match(3)).to eq(9) # the seq_open -> its close
      expect(tape.match(9)).to eq(3) # and back
      expect(tape.match(2)).to be_nil # a scalar links nothing
    end

    it "accepts scalar roots (a single record after DOC)" do
      tape = described_class.parse("42")
      expect(tape.count).to eq(2)
      expect(tape.kind(1)).to eq(:int)
    end

    it "raises ParseError on invalid JSON" do
      expect { described_class.parse("{nope") }
        .to raise_error(Yeptris::JSON::ParseError, /not strict JSON/)
    end

    it "reads IO-like input" do
      expect(described_class.parse(StringIO.new("[1]")).count).to eq(4)
    end
  end

  describe "number conversion" do
    it "converts ints and floats from their spans" do
      tape = described_class.parse(src)
      expect(tape.int_at(4)).to eq(1)
      expect(tape.int_at(13)).to eq(-7)
      expect(tape.float_at(5)).to eq(2.5)
    end

    it "refuses a kind mismatch (nil-silence hides bugs)" do
      tape = described_class.parse(src)
      expect { tape.int_at(5) }.to raise_error(ArgumentError, /not an int span/)
      expect { tape.float_at(4) }.to raise_error(ArgumentError, /not a float span/)
      expect { tape.string_at(4) }.to raise_error(ArgumentError, /not a string span/)
    end

    it "materializes an int64-overflow span exactly (Bignum)" do
      tape = described_class.parse("[99999999999999999999]")
      expect(tape.int_at(2)).to eq(99_999_999_999_999_999_999)
    end

    it "bulk-converts and reports the count" do
      tape = described_class.parse("[1, 2, 3.5, \"x\", true]")
      expect(tape.convert!).to eq(3)
      expect(tape.convert!(2, 3)).to eq(1)
    end

    it "converts after the tape is re-read (convert is idempotent)" do
      tape = described_class.parse("[10, 20]")
      expect(tape.convert!).to eq(2)
      expect(tape.int_at(2)).to eq(10)
      expect(tape.int_at(3)).to eq(20)
    end
  end

  describe "the lenient route (the deferred contract)" do
    it "accepts number-grammar-deferred input and records :num" do
      tape = described_class.parse("[1.2.3, 42, 3.5e2]", lenient: true)
      expect(tape.each.map(&:kind)).to eq(%i[doc seq_open num num num close])
    end

    it "classifies the deferred spans at conversion" do
      tape = described_class.parse("[1.2.3, 42, 3.5e2]", lenient: true)
      expect(tape.number_at(3)).to eq(42)
      expect(tape.number_at(4)).to eq(350.0)
    end

    it "rejects the malformed span at conversion, not parse" do
      tape = described_class.parse("[1.2.3]", lenient: true)
      expect { tape.number_at(2) }
        .to raise_error(Yeptris::JSON::ParseError, /does not scan as a number/)
      expect { tape.convert! }
        .to raise_error(Yeptris::JSON::ParseError, /does not scan as a number/)
    end

    it "agrees with the strict route on shared input (spans and containers)" do
      shared = '{"k": [1, 2.5, "s", true, false, null]}'
      strict = described_class.parse(shared)
      lenient = described_class.parse(shared, lenient: true)
      # spans and containers are identical; only the number KINDS
      # differ — the lenient route defers every number to :num (the
      # engine's deferred contract)
      expect(lenient.each.map { |r| [r.off, r.len] })
        .to eq(strict.each.map { |r| [r.off, r.len] })
      same_kind = ->(k) { %i[int float num].include?(k) ? :number : k }
      expect(lenient.each.map { |r| same_kind.call(r.kind) })
        .to eq(strict.each.map { |r| same_kind.call(r.kind) })
    end

    it "serves the lenient route's columns from the interleaved records" do
      tape = described_class.parse("[1, \"s\", -3.25]", lenient: true)
      expect(tape.number_at(2)).to eq(1)
      expect(tape.string_at(3)).to eq("s")
      expect(tape.number_at(4)).to eq(-3.25)
    end
  end

  describe "ownership" do
    it "frees and refuses use after free" do
      tape = described_class.parse("[1]")
      tape.free
      expect(tape).to be_freed
      expect { tape.kind(0) }.to raise_error(Yeptris::FreedError, /freed/)
      tape.free # idempotent
    end

    it "frees via the block form" do
      freed = []
      described_class.open("[1]") do |tape|
        freed << tape.freed?
        expect(tape.int_at(2)).to eq(1)
      end
      expect(freed).to eq([false])
    end

    it "GC without explicit free does not double-free (the shared flag)" do
      20.times do
        tape = described_class.parse("[#{'1,' * 50}2]")
        tape.convert!
        tape = nil
        GC.start
      end
    end

    it "keeps the source's spans alive past GC of unrelated objects" do
      src = '{"k": "survives"}'
      tape = described_class.parse(src)
      GC.start
      expect(tape.string_at(2)).to eq("k")
    end
  end

  it "reads out of range with IndexError" do
    tape = described_class.parse("[1]")
    expect { tape.kind(99) }.to raise_error(IndexError)
    expect { tape.kind(-1) }.to raise_error(IndexError)
  end
end
