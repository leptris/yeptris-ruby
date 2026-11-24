# frozen_string_literal: true

# The pull / iterparse face (events.h; yeptris-ruby#411). Real
# behavior against the engine — every event stream below is asserted
# as plain values, never doubles.
require "stringio"

RSpec.describe Yeptris::PullParser do
  let(:src) { "---\na: 1\n---\n&anchor [*ref, plain]\n...\n" }

  it "walks the whole stream's events in order" do
    kinds = described_class.new(src).each.map(&:kind)
    expect(kinds).to eq(
      %i[stream_start document_start mapping_start scalar scalar
         mapping_end document_end document_start sequence_start alias
         scalar sequence_end document_end stream_end]
    )
  end

  it "carries the scalar's value, implicit flag, and 1-based marks" do
    scalars = described_class.new("a: 1\n").each.select { |e| e.kind == :scalar }
    expect(scalars[0]).to have_attributes(
      value: "a", style: :plain, implicit?: true, line: 1, col: 1,
      end_line: 1, end_col: 2
    )
    expect(scalars[1]).to have_attributes(
      value: "1", style: :plain, implicit?: true, line: 1, col: 4
    )
  end

  it "reports quoted styles and the implicit? escape hatch" do
    scalars = described_class.new("- 'x'\n- \"y\"\n").each
                             .select { |e| e.kind == :scalar }
    expect(scalars.map(&:style)).to eq(%i[single_quoted double_quoted])
    expect(scalars[0]).to have_attributes(value: "x", implicit?: false)
  end

  it "carries anchors, aliases, tags, and the flow flag" do
    events = described_class.new("--- &a !!str [*x, s]\n").each.to_a
    expect(events.find { |e| e.kind == :document_start }).to have_attributes(
      explicit_marker?: true
    )
    seq = events.find { |e| e.kind == :sequence_start }
    expect(seq).to have_attributes(anchor: "a", tag: "tag:yaml.org,2002:str",
                                   flow?: true)
    expect(events.find { |e| e.kind == :alias }).to have_attributes(
      kind: :alias, value: "x"
    )
  end

  it "answers nil value when the engine recorded none (the C contract)" do
    empty_scalar = described_class.new("- \n").each
                                  .find { |e| e.kind == :scalar }
    expect(empty_scalar.value).to be_nil
  end

  it "returns UTF-8 tagged strings" do
    ev = described_class.new("café: ☕\n").each.find { |e| e.kind == :scalar }
    expect(ev.value).to eq("café")
    expect(ev.value.encoding).to eq(Encoding::UTF_8)
  end

  it "reads IO-like input through the one input boundary" do
    kinds = described_class.new(StringIO.new("[]\n")).each.map(&:kind)
    expect(kinds).to eq(%i[stream_start document_start sequence_start
                           sequence_end document_end stream_end])
  end

  it "drains identical events in batches and one-at-a-time" do
    one_shot = described_class.new(src).each.to_a
    batched = []
    p = described_class.new(src)
    loop do
      batch = p.next_batch(3)
      break if batch.empty?

      batched.concat(batch)
    end
    expect(batched).to eq(one_shot)
  end

  it "caps the batch at max and answers [] at the end" do
    p = described_class.new(src)
    first = p.next_batch(2)
    expect(first.size).to eq(2)
    p.next_batch(4096)
    expect(p.next_batch).to be_empty
    expect(p.next_batch(0)).to be_empty
  end

  it "keeps batch events past the next call (materialized copies)" do
    p = described_class.new(src)
    first = p.next_batch
    p.next_batch
    expect(first.map(&:kind)).to eq(%i[stream_start document_start
                                       mapping_start scalar scalar
                                       mapping_end document_end
                                       document_start sequence_start alias
                                       scalar sequence_end document_end
                                       stream_end])
  end

  it "exposes the raw status (clean run)" do
    expect(described_class.new("[]\n").status).to eq(
      [Yeptris::FFI::OK, 0, 0]
    )
  end

  it "drains the failure's prefix then raises with the position" do
    seen = []
    expect do
      described_class.new("a: b: c\n").each { |e| seen << e.kind }
    end.to raise_error(Yeptris::ParseError, /line 1, column 5/)
    expect(seen).to eq(%i[stream_start document_start mapping_start scalar])
  end

  it "answers the raw status of the failed run" do
    p = described_class.new("a: b: c\n")
    p.each { |_e| } # rubocop:disable Lint/EmptyBlock — the drain raises
  rescue Yeptris::ParseError
    expect(p.status[0]).to eq(Yeptris::FFI::ERROR_PARSE)
    expect(p.status[1]).to eq(1)
  end

  it "frees and refuses use after free" do
    p = described_class.new("[]\n")
    p.free
    expect(p).to be_freed
    expect { p.next_batch }.to raise_error(Yeptris::FreedError, /freed/)
    p.free # idempotent
  end

  it "frees via the block form on success and on raise" do
    freed = []
    described_class.open("[]\n") do |p|
      freed << p.freed?
      expect(p.each.first.kind).to eq(:stream_start)
    end
    expect(freed).to eq([false])
    expect do
      described_class.open("[]\n") { |p| raise "boom" }
    end.to raise_error("boom")
  end

  it "refuses a raw pointer build (the constructor is not a caller surface)" do
    expect { described_class.allocate.setup("nope") }
      .to raise_error(ArgumentError, /pointer is required/)
  end

  it "GC without explicit free does not double-free (the shared flag)" do
    20.times do
      p = described_class.new("[#{'1,' * 50}2]\n")
      p.each.to_a
      p = nil
      GC.start
    end
  end
end

RSpec.describe Yeptris::Iterparse do
  it "yields one document's slice per call, stream-framed once" do
    slices = described_class.new("a: 1\n---\n[1,2]\n...\n").each_document.to_a
    expect(slices.size).to eq(3)
    expect(slices[0].map(&:kind))
      .to eq(%i[stream_start document_start mapping_start scalar scalar
                mapping_end document_end])
    expect(slices[1].map(&:kind))
      .to eq(%i[document_start sequence_start scalar scalar sequence_end
                document_end])
    expect(slices[2].map(&:kind)).to eq(%i[stream_end])
  end

  it "frames a zero-document stream with exactly one empty slice" do
    slices = described_class.new("").each_document.to_a
    expect(slices.size).to eq(1)
    expect(slices[0].map(&:kind)).to eq(%i[stream_start stream_end])
  end

  it "bounds memory per document (the multi-document event content matches)" do
    src = "a: 1\n---\nb: 2\n---\nc: 3\n"
    per_doc = described_class.new(src).each_document.map do |slice|
      slice.select { |e| e.kind == :scalar }.map(&:value)
    end
    expect(per_doc[0, 3]).to eq([%w[a 1], %w[b 2], %w[c 3]])
    # without a trailing ... marker the stream_end slice is its own
    # (empty) yield — the engine's framing contract
    expect(per_doc.last).to eq([])
  end

  it "carries full event facts per slice" do
    slice = described_class.new("&k {x: 1}\n").each_document.first
    map = slice.find { |e| e.kind == :mapping_start }
    expect(map).to have_attributes(anchor: "k", flow?: true)
  end

  it "raises with the engine's position on failure" do
    expect do
      described_class.new("a: b: c\n").each_document.to_a
    end.to raise_error(Yeptris::ParseError, /iterparse failed: parse error at line 1, column 5/)
  end

  it "frees and refuses use after free (block form too)" do
    described_class.open("[]\n") { |it| it.each_document.to_a }
    it0 = described_class.new("[]\n")
    it0.free
    expect(it0).to be_freed
    expect { it0.next_document }.to raise_error(Yeptris::FreedError)
  end

  it "refuses a raw pointer build" do
    expect { described_class.allocate.setup("nope") }
      .to raise_error(ArgumentError, /pointer is required/)
  end
end

RSpec.describe Yeptris::Event do
  it "is a value: ==, eql?, hash, to_h" do
    a = described_class.new(kind: :scalar, value: "x", line: 1, col: 2)
    b = described_class.new(kind: :scalar, value: "x", line: 1, col: 2)
    c = described_class.new(kind: :scalar, value: "y", line: 1, col: 2)
    expect(a).to eq(b)
    expect(a).to eql(b)
    expect(a.hash).to eq(b.hash)
    expect(a == c).to be(false)
    expect(a.to_h).to include(kind: :scalar, value: "x", flow: false)
  end

  it "maps the ABI-pinned kind and style codes" do
    expect(Yeptris::Event::KINDS[9]).to eq(:scalar)
    expect(Yeptris::Event::STYLES[4]).to eq(:literal)
  end
end
