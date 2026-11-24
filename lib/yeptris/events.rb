# frozen_string_literal: true

require "yeptris"

module Yeptris
  # The streaming faces (engine events.h; yeptris-ruby#411, the rs
  # `pub mod event` / ts `events()` parity surface). Two consumption
  # models over the one engine event stream:
  #
  # * {Puller} — the StAX-style cursor: one event per #next, zero
  #   tree, memory bounded by the puller's own arena. The bulk
  #   #next_batch rides yeptris_pull_next_batch (fewer crossings).
  # * {Iterparse} — document-at-a-time over multi-document streams:
  #   one document's events per #next, the STREAM_START/STREAM_END
  #   pair framing the stream exactly once (in the first and last
  #   slices), the DOCUMENT_* pair framing every slice.
  #
  # Every {Event} carries plain Ruby values — value/anchor/tag are
  # COPIED out of the puller's arena at hand-out (the C strings are
  # valid only until the next call; nothing borrowed ever crosses to
  # the caller).
  module Events
    # events.h's YeptrisEventType — ABI-pinned order.
    EVENT_TYPES = {
      1 => :stream_start, 2 => :stream_end,
      3 => :document_start, 4 => :document_end,
      5 => :sequence_start, 6 => :sequence_end,
      7 => :mapping_start, 8 => :mapping_end,
      9 => :scalar, 10 => :alias,
    }.freeze
    private_constant :EVENT_TYPES

    # dom.h's scalar styles (the FFI STYLE_* codes); 0 = no style.
    STYLES = {
      ::Yeptris::FFI::STYLE_PLAIN => :plain,
      ::Yeptris::FFI::STYLE_SINGLE_QUOTED => :single_quoted,
      ::Yeptris::FFI::STYLE_DOUBLE_QUOTED => :double_quoted,
      ::Yeptris::FFI::STYLE_LITERAL => :literal,
      ::Yeptris::FFI::STYLE_FOLDED => :folded,
    }.freeze
    private_constant :STYLES

    # One engine event, plain Ruby values only.
    class Event
      attr_reader :kind, :style, :value, :anchor, :tag,
                  :line, :col, :end_line, :end_col
      # Collection/document/scalar facts (events.h's flag bits).
      attr_reader :flow, :explicit_marker, :implicit

      # @api private — minted by the puller/iterparse from the C
      # struct; the string fields copy here (the arena borrow ends at
      # this call).
      def initialize(c_ev)
        @kind = EVENT_TYPES.fetch(c_ev[:type], c_ev[:type])
        @style = STYLES[c_ev[:style]]
        @value = copy_span(c_ev[:value], c_ev[:value_len])
        @anchor = copy_span(c_ev[:anchor], c_ev[:anchor_len])
        @tag = copy_span(c_ev[:tag], c_ev[:tag_len])
        @line = c_ev[:line]
        @col = c_ev[:col]
        @end_line = c_ev[:end_line]
        @end_col = c_ev[:end_col]
        @flow = c_ev[:flow] != 0
        @explicit_marker = c_ev[:explicit_marker] != 0
        @implicit = c_ev[:implicit] != 0
      end

      # Collection events: flow style (`[a, b]` / `{a: b}`).
      alias flow? flow

      # Document events: the --- / ... markers were seen.
      alias explicit_marker? explicit_marker

      # Scalars: plain and untagged.
      alias implicit? implicit

      def inspect
        facts = [@kind]
        facts << @value.inspect if @value
        facts << "@#{anchor}" if anchor
        facts << "line #{line}, col #{col}"
        "#<#{self.class.name} #{facts.join(' ')}>"
      end

      private

      def copy_span(ptr, len)
        return nil if ptr.null? || len.zero?

        ptr.read_bytes(len).force_encoding(Encoding::UTF_8)
      end
    end

    # Shared close/free discipline: one release, idempotent, use after
    # close raises.
    module Handle
      def close
        return if @closed

        @closed = true
        yield_free
        nil
      end

      def freed?
        @closed
      end

      def ensure_alive!
        return unless @closed

        raise ::Yeptris::FreedError,
              "#{self.class.name.split('::').last} was closed"
      end

      private

      def with_handle!
        ensure_alive!
        @c_ptr
      end
    end
    private_constant :Handle

    # The StAX-style pull cursor. The engine parses the whole input at
    # .pull (the run completes into the cursor's arena), then hands
    # events out one (or one batch) at a time; a parse failure is
    # reported through #status with the 1-based position.
    class Puller
      include Enumerable
      include Handle

      # @api private — built by .pull
      def initialize(c_ptr)
        @c_ptr = c_ptr
        @closed = false
      end

      # The next event, or nil at stream end / on error (distinguish
      # with #status — the pull.c contract).
      def next
        p = with_handle!
        raw = ::Yeptris::FFI.yeptris_pull_next(p)
        return nil if raw.null?

        Event.new(::Yeptris::FFI::CEvent.new(raw))
      end

      # Up to +max+ events per call (yeptris_pull_next_batch): one
      # crossing per batch instead of one per event.
      def next_batch(max)
        p = with_handle!
        return [] if max <= 0

        buf = ::FFI::MemoryPointer.new(::Yeptris::FFI::CEvent, max)
        n = ::Yeptris::FFI.yeptris_pull_next_batch(p, buf, max)
        Array.new(n) do |i|
          Event.new(::Yeptris::FFI::CEvent.new(buf + i * ::Yeptris::FFI::CEvent.size))
        end
      end

      # The last call's verdict with its 1-based error position:
      # {status:} is 0 (OK) while events flow; non-zero with
      # {line:}/{col:} naming the failure (or 0,0 when the failure
      # carries no position).
      def status
        p = with_handle!
        line = ::FFI::MemoryPointer.new(:uint32)
        col = ::FFI::MemoryPointer.new(:uint32)
        st = ::Yeptris::FFI.yeptris_pull_status(p, line, col)
        { status: st, line: line.read_uint32, col: col.read_uint32 }
      end

      # Yields every event until the stream ends.
      def each
        return enum_for(:each) unless block_given?

        loop do
          ev = self.next
          break if ev.nil?

          yield ev
        end
        nil
      end

      private

      def yield_free
        ::Yeptris::FFI.yeptris_pull_free(@c_ptr)
      end
    end

    # Document-at-a-time iteration over multi-document streams: one
    # document's events per #next (an Array), memory bounded by the
    # largest document. Enumerable over the document slices.
    class Iterparse
      include Enumerable
      include Handle

      # @api private — built by .iterparse
      def initialize(c_ptr)
        @c_ptr = c_ptr
        @closed = false
      end

      # The next document's events (Array of Event), or nil when the
      # stream is exhausted. Raises Yeptris::ParseError when the
      # engine reports a parse failure (the position rides the
      # message).
      def next
        p = with_handle!
        count = ::FFI::MemoryPointer.new(:size_t)
        raw = ::Yeptris::FFI.yeptris_iterparse_next(p, count)
        if raw.null?
          st = status
          raise ::Yeptris::ParseError,
                "iterparse failed: status #{st[:status]} at line " \
                "#{st[:line]}, column #{st[:col]}" unless st[:status].zero?

          return nil # the legal end of stream
        end

        n = ::Yeptris::FFI.read_c_size_t(count)
        stride = ::Yeptris::FFI::CEvent.size
        Array.new(n) { |i| Event.new(::Yeptris::FFI::CEvent.new(raw + i * stride)) }
      end

      # Yields each slice (Enumerable over slices — the raw engine
      # stream, the STREAM_START/STREAM_END frames included).
      def each
        return enum_for(:each) unless block_given?

        loop do
          slice = self.next
          break if slice.nil?

          yield slice
        end
        nil
      end

      # Yields each DOCUMENT's event Array — the stream framing slices
      # (STREAM_START's opener and the lone STREAM_END) are skipped,
      # so this yields exactly one entry per document.
      def each_document
        return enum_for(:each_document) unless block_given?

        each do |slice|
          yield slice if slice.map(&:kind).include?(:document_start)
        end
        nil
      end

      def status
        p = with_handle!
        line = ::FFI::MemoryPointer.new(:uint32)
        col = ::FFI::MemoryPointer.new(:uint32)
        st = ::Yeptris::FFI.yeptris_iterparse_status(p, line, col)
        { status: st, line: line.read_uint32, col: col.read_uint32 }
      end

      private

      def yield_free
        ::Yeptris::FFI.yeptris_iterparse_free(@c_ptr)
      end
    end

    module_function

    # A pull cursor over +input+ (String or IO). The engine parses
    # eagerly; a syntactically invalid stream still yields a cursor —
    # its #next answers nil immediately and #status carries the
    # failure position.
    def pull(input)
      src = ::Yeptris.read_input(input).to_s
      p = ::Yeptris::FFI.yeptris_pull_new(src, src.bytesize)
      raise ::Yeptris::Error, "yeptris: pull cursor allocation failed" if p.null?

      Puller.new(p)
    end

    # A document-at-a-time iterator over +input+ (String or IO).
    def iterparse(input)
      src = ::Yeptris.read_input(input).to_s
      it = ::Yeptris::FFI.yeptris_iterparse_new(src, src.bytesize)
      raise ::Yeptris::Error, "yeptris: iterparse allocation failed" if it.null?

      Iterparse.new(it)
    end

    # The streaming faces' availability (engine with events.h's C
    # entries); at USE a stale engine still raises the attach stub's
    # message.
    def available?
      ::Yeptris::FFI::EVENTS
    end
  end
end
