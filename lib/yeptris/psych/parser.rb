# frozen_string_literal: true

module Yeptris
  module Psych
    # The event parser (TODO.impl/15 phase E): drives a Handler with
    # Psych's exact event shapes over the yeptris recorder — one bulk
    # record drain (the Materializer's seam), then a pure-Ruby
    # dispatch loop. No callback marshaling, no per-event FFI calls.
    class Parser
      attr_accessor :handler
      attr_reader :filename

      ANY = 0
      UTF8 = 1
      UTF16LE = 2
      UTF16BE = 3

      def initialize(handler = Handler.new)
        @handler = handler
        @filename = nil
      end

      def parse(yaml, filename = nil)
        yaml = yaml.read if yaml.respond_to?(:read)
        yaml = yaml.to_s
        @filename = filename
        flat, arena = Materializer.drain(yaml, schema: :compat_11)
        dispatch(flat, arena)
        self
      rescue ParseError => e
        raise SyntaxError, e.message
      end

      private

      STREAM_START = Materializer::STREAM_START
      STREAM_END = Materializer::STREAM_END
      DOCUMENT_START = Materializer::DOCUMENT_START
      DOCUMENT_END = Materializer::DOCUMENT_END
      SEQUENCE_START = Materializer::SEQUENCE_START
      MAPPING_START = Materializer::MAPPING_START
      SCALAR = Materializer::SCALAR
      ALIAS = Materializer::ALIAS

      EF_FLOW = 1 << 0
      EF_EXPLICIT = 1 << 1
      STYLE_PLAIN = 1
      STYLE_SINGLE_QUOTED = 2
      STYLE_DOUBLE_QUOTED = 3

      def dispatch(flat, arena)
        h = @handler
        i = 0
        while i < flat.length
          type = flat[i]
          style = flat[i + 1]
          flags = flat[i + 2]
          value = field(flat, arena, i + 6)
          anchor = field(flat, arena, i + 8)
          tag = field(flat, arena, i + 10)
          case type
          when STREAM_START then h.start_stream(UTF8)
          when STREAM_END then h.end_stream
          # version: [] when no %YAML directive (Psych's own shape);
          # a declared directive's [major, minor] is not carried by
          # the record — the one documented divergence
          when DOCUMENT_START then h.start_document([], [], (flags & EF_EXPLICIT).zero?)
          when DOCUMENT_END then h.end_document((flags & EF_EXPLICIT).zero?)
          when SEQUENCE_START
            h.start_sequence(anchor, tag, tag.nil?, (flags & EF_FLOW).zero? ? Handler::BLOCK : Handler::FLOW)
          when Materializer::SEQUENCE_END then h.end_sequence
          when MAPPING_START
            h.start_mapping(anchor, tag, tag.nil?, (flags & EF_FLOW).zero? ? Handler::BLOCK : Handler::FLOW)
          when Materializer::MAPPING_END then h.end_mapping
          when SCALAR
            # A synthesized empty scalar (empty document, '?' empty
            # key) carries style ANY(0); Psych's C emits plain(1)
            # with an empty String value — normalized here, at the
            # boundary, so the emitter's style chooser is untouched
            if style.zero?
              style = STYLE_PLAIN
            end
            value = +"" if value.nil?
            # libyaml's plain_implicit: a plain scalar that carried
            # no explicit tag (an explicit tag kills implicit typing)
            plain = style == STYLE_PLAIN && tag.nil?
            # quoted_implicit covers every explicit style — single,
            # double, literal, folded — when the tag was absent
            quoted = !plain && tag.nil? && style > STYLE_PLAIN
            h.scalar(value, anchor, tag, plain, quoted, style)
          when ALIAS then h.alias(value)
          end
          i += Materializer::FIELDS
        end
      end

      def field(flat, arena, at)
        len = flat[at + 1]
        return nil if len.zero?

        arena.byteslice(flat[at], len)
      end
    end
  end
end
