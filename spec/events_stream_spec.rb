# frozen_string_literal: true

# The streaming faces (yeptris-ruby#411; the rs `pub mod event` /
# ts `events()` parity surface): the StAX-style pull cursor and the
# document-at-a-time iterparse over one engine (events.h).
RSpec.describe Yeptris::Events do
  describe ".pull" do
    it "walks a stream event by event" do
      puller = described_class.pull("--- a\n--- b\n")

      kinds = puller.map(&:kind)

      expect(kinds.first).to eq(:stream_start)
      expect(kinds.last).to eq(:stream_end)
      expect(kinds).to include(:document_start, :document_end)
      expect(kinds).to include(:scalar)
      puller.close
    end

    it "exposes the scalar facts (value, anchor, tag, style, marks)" do
      puller = described_class.pull("--- &a !!int 42\n")
      ev = puller.find { |e| e.kind == :scalar }

      expect(ev.value).to eq("42")
      expect(ev.anchor).to eq("a")
      expect(ev.tag).to eq("tag:yaml.org,2002:int")
      expect(ev.style).to eq(:plain)
      expect(ev.line).to eq(1)
      # libyaml mark semantics: the node starts at its properties —
      # the anchor — not the scalar text
      expect(ev.col).to eq(5)
      puller.close
    end

    it "marks plain untagged scalars implicit" do
      puller = described_class.pull("--- 42\n")
      ev = puller.find { |e| e.kind == :scalar }

      expect(ev.implicit).to be(true)
      expect(ev.tag).to be_nil
      puller.close
    end

    it "reports collection flow style" do
      puller = described_class.pull("--- [1, 2]\n")
      seq = puller.find { |e| e.kind == :sequence_start }

      expect(seq.flow).to be(true)
      puller.close
    end

    it "batches events (the FFI pull_next_batch face)" do
      puller = described_class.pull("--- a\n--- b\n")
      drained = []
      loop do
        batch = puller.next_batch(3)
        break if batch.empty?

        drained.concat(batch.map(&:kind))
      end

      expect(drained.first).to eq(:stream_start)
      expect(drained.last).to eq(:stream_end)
      puller.close
    end

    it "reports the failure position on invalid input" do
      puller = described_class.pull("a: [1, 2\n")

      # events stream up to the failure, then end; the status carries
      # the failure position (the pull.c contract)
      puller.to_a
      expect(puller.next).to be_nil
      st = puller.status
      expect(st[:status]).not_to eq(0)
      expect(st[:line]).to be_positive

      puller.close
    end
  end

  describe ".iterparse" do
    it "yields one document's events per call" do
      iter = described_class.iterparse("--- a\n--- b\n--- c\n")
      slices = iter.to_a

      # the stream pair frames the WHOLE stream exactly once: the
      # first slice opens with STREAM_START, the last slice carries
      # STREAM_END alone (the iterparse.c framing)
      expect(slices.first.first.kind).to eq(:stream_start)
      expect(slices.last.map(&:kind)).to eq([:stream_end])
      # one document frame per document
      doc_slices = slices.select { |s| s.map(&:kind).include?(:document_start) }
      expect(doc_slices.size).to eq(3)
      expect(slices.flat_map { |s| s.map(&:kind) }.tally[:scalar]).to eq(3)
      iter.close
    end

    it "enumerates documents via each_document" do
      iter = described_class.iterparse("--- a\n--- b\n")
      docs = iter.each_document.to_a

      expect(docs.size).to eq(2)
      expect(docs[0].map(&:kind)).to include(:scalar)
      expect(docs[1].map(&:kind)).to include(:scalar)
      iter.close
    end

    it "reports the failure position on invalid input" do
      iter = described_class.iterparse("a: [1, 2\n")

      expect { iter.each_document.to_a }.to raise_error(Yeptris::ParseError)

      iter.close
    end
  end
end
