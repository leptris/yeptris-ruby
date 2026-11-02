# frozen_string_literal: true

# The multi-document stream API (yeptris#881): Yeptris::YAML.load_stream
# and Yeptris::Psych.load_stream at Psych parity — every document of a
# stream comes back, boundaries follow the spec (--- / ... markers,
# implicit documents after a ..., empty documents as nil), the block
# form yields, and the errors: knob covers the per-document
# rescue-and-skip consumers.
#
# The differential oracle runs in a CHILD PROCESS: the drop-in specs
# rebind ::Psych process-wide (psych_doc_marker_spec's note), so an
# in-process stdlib-psych oracle is not reliable across spec load
# order — the same discipline canon_parity_spec pins its literals by.
require "json"
require "open3"

RSpec.describe "load_stream (#881 multi-document stream API)" do
  describe "Yeptris::YAML.load_stream" do
    it "brings every document back from dump outputs joined with a newline (the round-trip shape)" do
      docs = [{ "a" => 1 }, { "b" => [true, nil] }, "plain"]
      stream = docs.map { |d| Yeptris::Psych.dump(d) }.join("\n")
      expect(Yeptris::YAML.load_stream(stream)).to eq(docs)

      y_stream = docs.map { |d| Yeptris::YAML.dump(d, header: true) }.join("\n")
      expect(Yeptris::YAML.load_stream(y_stream)).to eq(docs)
    end

    it "returns all five documents where string-splitting loses the trailing ones" do
      # The five-document, no-marker shape: split on ^--- sees ONE
      # slice, and a per-slice load keeps only the first document —
      # the exact loss the issue's consumers hit.
      stream = "d1\n...\nd2\n...\nd3\n...\nd4\n...\nd5\n"
      expect(stream.split(/^---/).length).to eq(1)
      expect(Yeptris::YAML.load(stream)).to eq("d1")
      expect(Yeptris::YAML.load_stream(stream)).to eq(%w[d1 d2 d3 d4 d5])

      # Mixed markers: the trailing implicit document merges into the
      # last --- slice under splitting and vanishes there too.
      mixed = "--- a\n--- b\n--- c\n--- d\n...\ne\n"
      expect(mixed.split(/^---/).map { |s| (Yeptris::YAML.load(s) rescue nil) }.compact.length).to eq(4)
      expect(Yeptris::YAML.load_stream(mixed)).to eq(%w[a b c d e])
    end

    it "folds bare scalar roots into one document and splits implicit documents after a ..." do
      # Marker-less consecutive scalar roots FOLD (psych parity).
      expect(Yeptris::YAML.load_stream("foo\nbar\n")).to eq(["foo bar"])
      # Implicit documents after a ... terminator parse individually —
      # the spec-legal marker-less boundary psych's parser is stricter
      # about (documented divergence, not exercised by the differential).
      expect(Yeptris::YAML.load_stream("d1\n...\nd2\n...\nd3\n")).to eq(%w[d1 d2 d3])
    end

    it "yields nil for empty documents and [] for a stream with no documents" do
      expect(Yeptris::YAML.load_stream("---\n---\nfoo: 1\n---\n")).to eq([nil, { "foo" => 1 }, nil])
      expect(Yeptris::YAML.load_stream("")).to eq([])
      expect(Yeptris::YAML.load_stream("\n")).to eq([])
      expect(Yeptris::YAML.load_stream("# comment only\n")).to eq([])
      expect(Yeptris::YAML.load_stream("---\n")).to eq([nil])
    end

    it "honors explicit ... end markers" do
      stream = "---\nfoo: 1\n...\n---\nbar: 2\n...\n"
      expect(Yeptris::YAML.load_stream(stream)).to eq([{ "foo" => 1 }, { "bar" => 2 }])
    end

    it "applies the schema knob per document" do
      stream = "---\nv: yes\n---\nw: no\n"
      expect(Yeptris::YAML.load_stream(stream, schema: :compat_11))
        .to eq([{ "v" => true }, { "w" => false }])
      expect(Yeptris::YAML.load_stream(stream, schema: :core_12))
        .to eq([{ "v" => "yes" }, { "w" => "no" }])
    end

    it "raises on the first bad document by default" do
      bad = "---\na: 1\n---\nb: [unclosed\n---\nc: 3\n"
      expect { Yeptris::YAML.load_stream(bad) }.to raise_error(Yeptris::ParseError)
    end

    it "errors: :collect returns per-document results with error markers" do
      bad = "---\na: 1\n---\nb: [unclosed\n---\nc: 3\n"
      collected = Yeptris::YAML.load_stream(bad, errors: :collect)
      expect(collected[0]).to eq({ "a" => 1 })
      expect(collected[1]).to be_a(Yeptris::ParseError)
      expect(collected[2]).to eq({ "c" => 3 })

      # A good stream collects to the same plain array as :raise.
      good = "---\na: 1\n---\nb: 2\n"
      expect(Yeptris::YAML.load_stream(good, errors: :collect))
        .to eq([{ "a" => 1 }, { "b" => 2 }])
    end

    it "rejects an unknown errors: value" do
      expect { Yeptris::YAML.load_stream("---\na: 1\n", errors: :bogus) }
        .to raise_error(ArgumentError, /errors:/)
    end

    it "block form yields every document and returns the array" do
      seen = []
      result = Yeptris::YAML.load_stream("---\na: 1\n---\n---\nb: 2\n") { |d| seen << d }
      expect(seen).to eq([{ "a" => 1 }, nil, { "b" => 2 }])
      expect(result).to eq([{ "a" => 1 }, nil, { "b" => 2 }])

      # Collect + block: the markers ride through the block too.
      marked = []
      collected = Yeptris::YAML.load_stream("---\na: 1\n---\nb: [x\n", errors: :collect) do |d|
        marked << d.class
      end
      expect(marked).to eq([Hash, Yeptris::ParseError])
      expect(collected.length).to eq(2)
    end
  end

  describe "Yeptris::Psych.load_stream" do
    it "matches stdlib's faces: arrays, nil placement, block yields" do
      expect(Yeptris::Psych.load_stream("---\nfoo: 1\n---\n---\nbar\n"))
        .to eq([{ "foo" => 1 }, nil, "bar"])
      expect(Yeptris::Psych.load_stream("--- 1\n--- 2\n")).to eq([1, 2])
      expect(Yeptris::Psych.load_stream("")).to eq([])

      seen = []
      result = Yeptris::Psych.load_stream("---\na: 1\n---\nb: 2\n") { |d| seen << d }
      expect(seen).to eq([{ "a" => 1 }, { "b" => 2 }])
      expect(result).to eq([{ "a" => 1 }, { "b" => 2 }])
      expect(Yeptris::Psych.safe_load_stream("---\na: 1\n---\nb: 2\n"))
        .to eq([{ "a" => 1 }, { "b" => 2 }])
    end

    it "raises stdlib's error family for a bad document; collect carries the markers" do
      bad = "---\na: 1\n---\nb: [unclosed\n"
      expect { Yeptris::Psych.load_stream(bad) }.to raise_error(Yeptris::Psych::SyntaxError)

      collected = Yeptris::Psych.load_stream("---\na: 1\n---\nb: [x\n---\nc: 3\n", errors: :collect)
      expect(collected[0]).to eq({ "a" => 1 })
      expect(collected[1]).to be_a(Yeptris::Psych::SyntaxError)
      expect(collected[2]).to eq({ "c" => 3 })
    end

    it "reads an IO input once (the collect fallback sees the same bytes)" do
      require "stringio"
      expect(Yeptris::Psych.load_stream(StringIO.new("---\na: 1\n---\nb: [x\n"), errors: :collect)[0])
        .to eq({ "a" => 1 })
      expect(Yeptris::YAML.load_stream(StringIO.new("---\na: 1\n---\nb: 2\n")))
        .to eq([{ "a" => 1 }, { "b" => 2 }])
    end
  end

  describe "the drain ladder (every rung load_stream may take)" do
    it "agrees on the document list across the record and columnar runs" do
      stream = "---\nfoo: 1\n---\n---\nbar\n...\nbaz\n"
      want = [{ "foo" => 1 }, nil, "bar", "baz"]
      expect(Yeptris::ValueML.load_all(stream, schema: :compat_11)).to eq(want)
      expect(Yeptris::ValueML.load_all_columns(stream, schema: :compat_11)).to eq(want)
    end
  end

  describe "differential vs stdlib Psych (child-process oracle)" do
    CORPUS = [
      "---\na: 1\n---\nb: 2\n",
      "--- 1\n--- 2\n--- 3\n",
      "---\nfoo: 1\n---\n---\nbar\n",
      "---\n---\nfoo: 1\n---\n---\n",
      "---\nfoo: 1\n...\n---\nbar: 2\n",
      "foo\n---\nbar\n",
      "---\n- 1\n- 2\n---\nx: {y: [1, 2]}\n",
      "---\n# comment doc\n---\na: 1\n",
      "--- yes\n---\nv: no\n---\nn: 7\n",
      "---\na:\n  b:\n    - c: 1\n---\nz: 9\n",
    ].freeze

    def psych_oracle(streams)
      script = <<~'RUBY'
        require "psych"
        require "json"
        out = []
        $stdin.read.split("\0", -1).each do |src|
          begin
            docs = Psych.load_stream(src)
            docs = [] unless docs.is_a?(Array)
            out << docs.map { |d| d.nil? ? "nil" : "doc" }.join(",")
          rescue Psych::SyntaxError, Psych::Exception
            out << "RAISE"
          end
        end
        puts JSON.generate(out)
      RUBY
      out, err, st = Open3.capture3(RbConfig.ruby, "-e", script, stdin_data: streams.join("\0"))
      raise "psych oracle failed: #{err}" unless st.success?

      JSON.parse(out)
    end

    it "agrees on document count and nil placement for every parseable stream" do
      verdicts = psych_oracle(CORPUS)
      parsed = 0
      CORPUS.each_with_index do |src, i|
        next if verdicts[i] == "RAISE" # documented psych-strict shapes

        parsed += 1
        want = verdicts[i].split(",")
        [Yeptris::YAML, Yeptris::Psych].each do |face|
          got = face.load_stream(src)
          shape = got.map { |d| d.nil? ? "nil" : "doc" }
          expect(shape).to eq(want),
                           "stream #{src.inspect} via #{face}: yeptris #{shape.inspect} " \
                           "vs psych #{want.inspect}"
        end
      end
      expect(parsed).to be_positive
    end
  end
end
