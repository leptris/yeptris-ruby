# frozen_string_literal: true

# The pull / iterparse face (events.h; TODO.impl/12, yeptris-ruby#411).
#
# Two consumption models over the one parse engine, both ZERO C->host
# dispatch (the FFI-friendly shapes — one bulk crossing per batch,
# never a per-event callback):
#
#   * {PullParser} — the StAX cursor: the whole stream is captured at
#     construction and handed out event by event (or in bulk batches).
#   * {Iterparse} — document-at-a-time over multi-document streams:
#     one document's events per call, memory bounded by the largest
#     document.
#
# Event strings are owned by the engine and valid UNTIL THE NEXT CALL,
# so every crossing materializes plain {Event} values — no borrowed
# memory, no FFI pointer, ever escapes this module. The models'
# identical event streams are the engine's own cross-model corpus
# contract (test_events_cross).
#
# Engines without the face raise a friendly error at use (the EVENTS
# capability probe gates the message).
module Yeptris
  # One event: a plain value class (==, eql?, hash, to_h — never an
  # FFI wrapper). +kind+ mirrors the engine's YeptrisEventType
  # (:stream_start .. :alias); +style+ the scalar presentation
  # (:plain, :single_quoted, :double_quoted, :literal, :folded; :any
  # for non-scalars). +value+ is the scalar content or alias name —
  # nil when the engine recorded none (the empty scalar reads as
  # NULL; the event face mirrors the C contract, unlike the DOM
  # face's ""). +anchor+/+tag+ are the node properties when present.
  # The marks are 1-based; +end_col+ is one past the node's end token
  # (the engine's libyaml end_mark law, #179).
  class Event
    attr_reader :kind, :style, :value, :anchor, :tag,
                :line, :col, :end_line, :end_col

    def initialize(kind:, style: :any, value: nil, anchor: nil, tag: nil,
                   flow: false, explicit_marker: false, implicit: false,
                   line: 0, col: 0, end_line: 0, end_col: 0)
      @kind = kind
      @style = style
      @value = value
      @anchor = anchor
      @tag = tag
      @flow = flow
      @explicit_marker = explicit_marker
      @implicit = implicit
      @line = line
      @col = col
      @end_line = end_line
      @end_col = end_col
    end

    # Collection in flow style ({}/[]).
    def flow?
      @flow
    end

    # Document framed by an explicit --- / ... marker.
    def explicit_marker?
      @explicit_marker
    end

    # Plain-style scalar, as the engine records the flag — set for
    # PLAIN scalars even when a tag is present (the tag rides #tag);
    # quoting is the escape hatch.
    def implicit?
      @implicit
    end

    def ==(other)
      other.is_a?(Event) && kind == other.kind && style == other.style &&
        value == other.value && anchor == other.anchor && tag == other.tag &&
        flow? == other.flow? && explicit_marker? == other.explicit_marker? &&
        implicit? == other.implicit? && line == other.line &&
        col == other.col && end_line == other.end_line && end_col == other.end_col
    end
    alias eql? ==

    def hash
      [kind, style, value, anchor, tag, flow?, explicit_marker?, implicit?,
       line, col, end_line, end_col].hash
    end

    def to_h
      { kind: kind, style: style, value: value, anchor: anchor, tag: tag,
        flow: flow?, explicit_marker: explicit_marker?, implicit: implicit?,
        line: line, col: col, end_line: end_line, end_col: end_col }
    end

    def inspect
      "#<#{self.class.name} #{kind} value=#{value.inspect} anchor=#{anchor.inspect} " \
        "tag=#{tag.inspect} line=#{line} col=#{col}>"
    end

    # @api private — the engine's ABI-pinned event codes (events.h).
    KINDS = {
      1 => :stream_start, 2 => :stream_end,
      3 => :document_start, 4 => :document_end,
      5 => :sequence_start, 6 => :sequence_end,
      7 => :mapping_start, 8 => :mapping_end,
      9 => :scalar, 10 => :alias,
    }.freeze
    STYLES = {
      0 => :any, 1 => :plain, 2 => :single_quoted, 3 => :double_quoted,
      4 => :literal, 5 => :folded,
    }.freeze

    # @api private — one engine event -> one plain value. The C strings
    # die at the next pull call, so every field materializes here.
    def self.from_c(ev)
      new(
        kind: KINDS.fetch(ev[:type]),
        style: STYLES.fetch(ev[:style], :any),
        value: read_span(ev, :value, :value_len),
        anchor: read_span(ev, :anchor, :anchor_len),
        tag: read_span(ev, :tag, :tag_len),
        flow: ev[:flow] != 0,
        explicit_marker: ev[:explicit_marker] != 0,
        implicit: ev[:implicit] != 0,
        line: ev[:line], col: ev[:col],
        end_line: ev[:end_line], end_col: ev[:end_col],
      )
    end

    def self.read_span(ev, ptr_field, len_field)
      p = ev[ptr_field]
      return nil if p.null?

      len = ev[len_field]
      len.zero? ? "" : p.read_bytes(len).force_encoding(Encoding::UTF_8)
    end
    private_class_method :read_span
  end

  # The shared status plumbing of the two cursors.
  module EventsSupport
    STATUS_NAMES = {
      ::Yeptris::FFI::ERROR_PARSE => "parse",
      ::Yeptris::FFI::ERROR_MEMORY => "memory",
      ::Yeptris::FFI::ERROR_ENCODING => "encoding",
      ::Yeptris::FFI::ERROR_ARG => "argument",
    }.freeze

    # The cursor's status verdict as the raised error (nil when clean):
    # the puller/iterparse carry their own error slot — the TLS channel
    # the other faces read is NOT this route's, so the position comes
    # from the status call, never yeptris_last_error.
    def status_error(raw_status, line, col, action)
      return nil if raw_status == ::Yeptris::FFI::OK

      name = STATUS_NAMES.fetch(raw_status, "status #{raw_status}")
      pos = line.positive? ? " at line #{line}, column #{col}" : ""
      ::Yeptris::ParseError.new("#{action} failed: #{name} error#{pos}")
    end

    def read_input(source)
      ::Yeptris.read_input(source).to_s
    end
  end
  private_constant :EventsSupport

  # The StAX-style pull cursor (events.h pull): the whole stream is
  # captured into the puller's event store at construction; the cursor
  # hands events out one bulk batch at a time. Ownership mirrors
  # {Yeptris::Document}: an explicit #free and a GC finalizer flip the
  # same freed flag.
  #
  #   Yeptris::PullParser.new("a: 1\n---\nb: 2\n").each.to_a
  #   # => [#<Event stream_start>, #<Event document_start>, ...]
  #
  # A failed run is terminal and yields its prefix first (the
  # recorder's drain law): #each drains every event captured before
  # the failure, then raises ParseError with the engine's position.
  class PullParser
    include EventsSupport

    # Shared between the instance and its finalizer (the leptris-ruby
    # double-free fix).
    Freed = Struct.new(:state) # :alive | :freed

    # Starts a pull cursor over +source+ (YAML; any encoding the engine
    # front-end serves — BOM sniffing and UTF-16/32 transcoding ride
    # the same front door as every parse face). The only construction
    # failure is the host allocation behind the puller; parse failures
    # surface at the drain end.
    def self.new(source)
      unless ::Yeptris::FFI::EVENTS
        raise ::Yeptris::Error,
              "yeptris: the pull/iterparse face needs a newer libyeptris; " \
              "the loaded library predates it. Update the engine library."
      end
      source = ::Yeptris.read_input(source).to_s
      ptr = ::Yeptris::FFI.yeptris_pull_new(source, source.bytesize)
      raise ::Yeptris::Error, "pull_new failed — out of memory" if ptr.null?

      obj = allocate
      obj.setup(ptr)
      obj
    end

    # Block form: the cursor frees when the block exits (valid or not).
    def self.open(source)
      puller = new(source)
      begin
        yield puller
      ensure
        puller.free
      end
    end

    # @api private — wired by .new; a raw pointer is not a caller
    # surface (the same contract as Document).
    def setup(c_ptr)
      unless c_ptr.is_a?(::FFI::Pointer)
        raise ArgumentError,
              "a puller FFI pointer is required — build pullers with " \
              "Yeptris::PullParser.new"
      end

      @c_ptr = c_ptr
      @freed = Freed.new(:alive)
      ObjectSpace.define_finalizer(self, self.class.finalize(c_ptr)) unless c_ptr.null?
    end

    def each(&block)
      return enum_for(:each) unless block

      loop do
        batch = next_batch
        break if batch.empty?

        batch.each { |event| block.call(event) }
      end
      raise_drain_error!
    end

    # The bulk face (the FFI shape): up to +max+ events per call, one
    # FFI crossing per batch. Returns [] at stream end. The engine's
    # strings die at the next call; the returned {Event} values are
    # plain copies and outlive it.
    def next_batch(max = 256)
      ensure_alive!
      return [].freeze if max <= 0

      buf = ::FFI::MemoryPointer.new(::Yeptris::FFI::CEvent, max)
      n = ::Yeptris::FFI.yeptris_pull_next_batch(@c_ptr, buf, max)
      Array.new(n) do |i|
        ::Yeptris::Event.from_c(
          ::Yeptris::FFI::CEvent.new(buf + i * ::Yeptris::FFI::CEvent.size)
        )
      end
    end

    # [status, line, col]: the raw verdict of the run behind the
    # cursor — FFI::OK when clean; the 1-based failure position (0
    # where the failure carries none).
    def status
      ensure_alive!
      line = ::FFI::MemoryPointer.new(:uint32)
      col = ::FFI::MemoryPointer.new(:uint32)
      st = ::Yeptris::FFI.yeptris_pull_status(@c_ptr, line, col)
      [st, line.read_uint32, col.read_uint32]
    end

    def raise_drain_error!
      st, line, col = status
      err = status_error(st, line, col, "pull")
      raise err if err
    end

    def ensure_alive!
      raise ::Yeptris::FreedError, "pull parser is freed" if @freed.state == :freed
    end

    def free
      return if @freed.state == :freed

      @freed.state = :freed
      ObjectSpace.undefine_finalizer(self)
      ::Yeptris::FFI.yeptris_pull_free(@c_ptr)
    end

    def freed?
      @freed.state == :freed
    end

    # Pointer-only finalizer (Document's law): no Ruby objects, no
    # wrapper — a finalizer closing over the wrapper races its sweep.
    def self.finalize(c_ptr)
      proc { ::Yeptris::FFI.yeptris_pull_free(c_ptr) }
    end
  end

  # Document-at-a-time iteration over multi-document streams (events.h
  # iterparse): one document's events per call, memory bounded by the
  # largest document. STREAM_START / STREAM_END frame the stream
  # exactly once each; the DOCUMENT_* pair frames each yielded slice —
  # so a stream with zero documents still yields one slice carrying
  # the framing pair (the engine's contract).
  #
  #   Yeptris::Iterparse.new("---\na: 1\n---\nb: 2\n").each_document.to_a
  #   # => [[stream_start, document_start, .., document_end],
  #   #     [document_start, .., document_end, stream_end]]
  class Iterparse
    include EventsSupport

    Freed = Struct.new(:state) # :alive | :freed

    # Starts an iterator over +source+ (see {PullParser.new}).
    def self.new(source)
      unless ::Yeptris::FFI::EVENTS
        raise ::Yeptris::Error,
              "yeptris: the pull/iterparse face needs a newer libyeptris; " \
              "the loaded library predates it. Update the engine library."
      end
      source = ::Yeptris.read_input(source).to_s
      ptr = ::Yeptris::FFI.yeptris_iterparse_new(source, source.bytesize)
      raise ::Yeptris::Error, "iterparse_new failed — out of memory" if ptr.null?

      obj = allocate
      obj.setup(ptr)
      obj
    end

    # Block form: the iterator frees when the block exits (valid or
    # not).
    def self.open(source)
      it = new(source)
      begin
        yield it
      ensure
        it.free
      end
    end

    # @api private — wired by .new; a raw pointer is not a caller
    # surface.
    def setup(c_ptr)
      unless c_ptr.is_a?(::FFI::Pointer)
        raise ArgumentError,
              "an iterparse FFI pointer is required — build iterators " \
              "with Yeptris::Iterparse.new"
      end

      @c_ptr = c_ptr
      @freed = Freed.new(:alive)
      ObjectSpace.define_finalizer(self, self.class.finalize(c_ptr)) unless c_ptr.null?
    end

    def each_document(&block)
      return enum_for(:each_document) unless block

      while (slice = next_document)
        block.call(slice)
      end
    end

    # The next document's events (one FFI crossing), or nil when the
    # stream is exhausted. Raises ParseError when the run failed (the
    # engine's position folded in).
    def next_document
      ensure_alive!
      count = ::FFI::MemoryPointer.new(:size_t)
      raw = ::Yeptris::FFI.yeptris_iterparse_next(@c_ptr, count)
      if raw.null?
        st, line, col = status
        err = status_error(st, line, col, "iterparse")
        raise err if err

        return nil
      end
      n = ::Yeptris::FFI.read_c_size_t(count)
      Array.new(n) do |i|
        ::Yeptris::Event.from_c(
          ::Yeptris::FFI::CEvent.new(raw + i * ::Yeptris::FFI::CEvent.size)
        )
      end
    end

    # [status, line, col] — the raw verdict (see {PullParser#status}).
    def status
      ensure_alive!
      line = ::FFI::MemoryPointer.new(:uint32)
      col = ::FFI::MemoryPointer.new(:uint32)
      st = ::Yeptris::FFI.yeptris_iterparse_status(@c_ptr, line, col)
      [st, line.read_uint32, col.read_uint32]
    end

    def ensure_alive!
      raise ::Yeptris::FreedError, "iterparse is freed" if @freed.state == :freed
    end

    def free
      return if @freed.state == :freed

      @freed.state = :freed
      ObjectSpace.undefine_finalizer(self)
      ::Yeptris::FFI.yeptris_iterparse_free(@c_ptr)
    end

    def freed?
      @freed.state == :freed
    end

    def self.finalize(c_ptr)
      proc { ::Yeptris::FFI.yeptris_iterparse_free(c_ptr) }
    end
  end
end
