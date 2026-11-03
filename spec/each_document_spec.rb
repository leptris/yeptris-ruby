# frozen_string_literal: true

require "yeptris"

RSpec.describe Yeptris::YAML do
  describe ".each_document" do
    it "yields every valid document with nil error, in stream order" do
      pairs = []
      described_class.each_document("--- 41\n--- \"42\"\n---\n") do |doc, error|
        pairs << [doc, error]
      end
      expect(pairs).to eq([[41, nil], ["42", nil], [nil, nil]])
    end

    it "returns an Enumerator without a block" do
      enum = described_class.each_document("---\na: 1\n---\nb: 2\n")
      expect(enum).to be_a(Enumerator)
      expect(enum.to_a).to eq([[{ "a" => 1 }, nil], [{ "b" => 2 }, nil]])
    end

    it "fails each marker-line map document exactly like Psych (the #915 law)" do
      # `--- a: 1` on ONE line is rejected by libyaml/Psych/PyYAML at
      # 1:6 — the tolerant walk surfaces EACH such document as its own
      # failure, and the whole stream terminates only because both
      # documents carry the rejected shape.
      pairs = described_class.each_document("--- a: 1\n--- b: 2\n").to_a
      expect(pairs.length).to eq(2)
      expect(pairs[0][0]).to be_nil
      expect(pairs[0][1].message).to include("line 1")
      expect(pairs[0][1].message).to include("column 6")
      expect(pairs[1][0]).to be_nil
      expect(pairs[1][1].message).to include("column 6")
    end

    it "keeps the valid documents around a bad one, error carries index + line" do
      pairs = []
      src = "--- ok_one\n--- {{{{ bad\n--- ok_two\n"
      described_class.each_document(src) { |doc, error| pairs << [doc, error] }
      expect(pairs[0]).to eq(["ok_one", nil])
      expect(pairs[1][0]).to be_nil
      expect(pairs[1][1]).to be_a(Yeptris::ParseError)
      expect(pairs[1][1].message).to include("stream document 1")
      expect(pairs[1][1].message).to include("line 2")
      expect(pairs[2]).to eq(["ok_two", nil])
    end

    it "ends the walk on an unrecoverable tail, never hangs" do
      pairs = []
      deep = "[" * 1200 + "]" * 1200
      described_class.each_document("--- [1]\n#{deep}\n") do |doc, error|
        pairs << [doc, error]
      end
      expect(pairs.length).to eq(1)
      expect(pairs[0][0]).to be_nil
      expect(pairs[0][1]).to be_a(Yeptris::ParseError)
    end

    it "frames scanner-accurately: a quoted marker-looking line is ONE failure" do
      # the grammar itself rejects the scalar; the raw-marker resync
      # then lands on the --- INSIDE the quoted text (the failed frame
      # has no scanner-defined extent — the honest best effort), so
      # the tail's remainder parses as the plain scalar it looks like.
      # The pin: the walk terminates, the failure is one unit, the
      # tail surfaces best-effort, nothing crashes or hangs.
      pairs = []
      described_class.each_document("\"line one\n---\nline two\"\n") do |doc, error|
        pairs << [doc, error]
      end
      expect(pairs.length).to eq(2)
      expect(pairs[0][0]).to be_nil
      expect(pairs[0][1]).to be_a(Yeptris::ParseError)
      expect(pairs[1]).to eq(["line two\"", nil])
    end

    it "is empty for the empty stream and yields nothing for comments" do
      expect(described_class.each_document("").to_a).to eq([])
      expect(described_class.each_document("# just a comment\n").to_a).to eq([])
    end

    it "rides the schema option on every frame" do
      # compat_11 (default, the Psych/libyaml surface) keeps 0o7 a
      # string; core_12's resolver types it octal. Each frame rides
      # the schema the iterator was built with.
      expect(described_class.each_document("--- 0o7\n").to_a).to eq([["0o7", nil]])
      expect(described_class.each_document("--- 0o7\n", schema: :core_12).to_a).to eq([[7, nil]])
    end

    it "recovers past a depth failure with max_depth set" do
      deep = "[" * 50 + "]" * 50
      src = "--- #{deep}\n--- recovered\n"
      pairs = []
      described_class.each_document(src, max_depth: 10) { |d, e| pairs << [d, e] }
      expect(pairs[0][0]).to be_nil
      expect(pairs[0][1].message).to include("depth limit exceeded")
      expect(pairs[1]).to eq(["recovered", nil])
    end
  end
end
