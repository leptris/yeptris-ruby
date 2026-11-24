# frozen_string_literal: true

require "yeptris"

module Yeptris
  module JSON
    # The public columnar tape face (engine tape.h; yeptris-ruby#411):
    # ONE fused strict parse per document, records exposed as typed
    # columns — no Ruby tree materializes. {Yeptris::JSON.load} rides
    # this engine internally; the face hands the columnar data to the
    # caller (the simdjson-class shape the C users and the rs/ts
    # siblings share).
    #
    #     tape = Yeptris::JSON::Tape.parse('{"a":[1,2],"b":"x"}')
    #     tape.kinds   # => [:map_open, :str, :seq_open, :int, :int, :close, :str, :close]
    #     tape.value(i) # => the record's scalar (nil for structure)
    #
    # The spans borrow the caller's bytes: the tape retains the source
    # string (the borrow law), and #value/#kinds answer plain Ruby.
    # #free releases the engine's block; a tape left to GC still
    # frees (the Document finalizer pattern).
    class Tape
      # Shared between the instance and its GC finalizer (Procs close
      # over variables by reference — the Document pattern).
      Freed = Struct.new(:flag)

      # tape.h's record kinds (the kinds column), ABI-pinned.
      RECORD_KINDS = {
        0 => :doc, 1 => :null, 2 => :true, 3 => :false,
        4 => :int, 5 => :float, 6 => :str,
        7 => :seq_open, 8 => :map_open, 9 => :close,
        10 => :num, # the lenient route's deferred number
      }.freeze
      private_constant :RECORD_KINDS

      SPAN_KINDS = %i[int float str num].freeze
      private_constant :SPAN_KINDS

      # Raised when a deferred (lenient) number span fails the
      # convert pass, or an INT span exceeds int64.
      class Error < ::Yeptris::JSON::Error; end

      # Parses strict JSON (or, with +lenient:+, the deferred-number
      # route whose structural checks run at parse and the NUMBER
      # grammar defers to materialize). Raises
      # {Yeptris::JSON::ParseError} with the engine's detail.
      def self.parse(json, lenient: false)
        src = ::Yeptris.read_input(json).to_s
        tape = ::Yeptris::FFI::JsonTape.new
        rc = lenient ? ::Yeptris::FFI.yeptris_parse_json_tape_lenient(src, src.bytesize, tape)
                     : ::Yeptris::FFI.yeptris_parse_json_tape(src, src.bytesize, tape)
        raise ::Yeptris::JSON::ParseError,
              ::Yeptris::FFI.last_error_message unless rc == ::Yeptris::FFI::OK

        # the columns-lazy law (tape.h): the lenient route stores the
        # interleaved records as primary; consumers reading the
        # column pointers materialize them once first
        unless ::Yeptris::FFI.yeptris_tape_columns(tape.to_ptr).zero?
          ::Yeptris::FFI.yeptris_tape_free(tape.to_ptr)
          raise Error, "yeptris: tape column materialization failed"
        end

        new(src, tape, Freed.new(false))
      end

      # @api private — minted by .parse
      def initialize(src, tape, freed)
        # the spans borrow the source: retain it or every later span
        # read points at collected memory (the Document @source law)
        @source = src
        @tape = tape
        @c_ptr = tape
        @freed = freed
        ObjectSpace.define_finalizer(self, self.class.finalize(tape.to_ptr, freed))
      end

      def self.finalize(ptr, freed)
        proc do
          next if freed.flag

          freed.flag = true
          ::Yeptris::FFI.yeptris_tape_free(ptr)
        end
      end

      # The record count (one record per token; the :doc boundary
      # record leads).
      def count
        ensure_alive!
        @tape[:count]
      end
      alias size count

      # Every record's kind, as symbols (tape.h's record kinds).
      def kinds
        ensure_alive!
        @kinds ||= @tape[:kinds].read_bytes(@tape[:count]).unpack("C*")
                                .map { |k| RECORD_KINDS.fetch(k, k) }
      end

      # The record's source span as [offset, length] into the parsed
      # bytes (INT/FLOAT/STR/NUM records; nil for the others —
      # container records carry LINKS in the offset, read those with
      # #match).
      def span(i)
        ensure_alive!
        return nil unless SPAN_KINDS.include?(kinds[i])

        [offs[i], lens[i]]
      end

      # The record's scalar value materialized: nil / true / false,
      # Integer, Float, decoded String. Structure records (:doc,
      # opens, :close) answer nil. NUM records that fail the convert
      # pass and int64-overflowing INT spans raise {Error}.
      def value(i)
        ensure_alive!
        case kinds[i]
        when :null then nil
        when :true then true
        when :false then false
        when :int, :float, :num then number(i)
        when :str then ::Yeptris::JSON.decode_span(@source, offs[i], lens[i])
        else nil # :doc and the container structure
        end
      end

      # The container link: SEQ_OPEN/MAP_OPEN answer the index of the
      # matching CLOSE; CLOSE answers its matching OPEN. nil elsewhere.
      def match(i)
        ensure_alive!
        k = kinds[i]
        return nil unless %i[seq_open map_open close].include?(k)

        offs[i]
      end

      def free
        return if @freed.flag

        @freed.flag = true
        ObjectSpace.undefine_finalizer(self)
        ::Yeptris::FFI.yeptris_tape_free(@tape.to_ptr)
        nil
      end

      def freed?
        @freed.flag
      end

      # Applies a compiled {Yeptris::Plan} to this tape in one C pass
      # (the tape leg of the plan walk): typed columns, no per-record
      # host dispatch.
      def plan_walk(plan)
        ::Yeptris::Plan.walk_tape(self, plan)
      end

      # @api private — the raw FFI struct (Plan's tape-leg reader)
      attr_reader :c_ptr

      # @api private — the retained source (Plan's tape-leg reader
      # decodes string columns from it)
      attr_reader :source

      private

      def ensure_alive!
        return unless @freed.flag

        raise Error, "the tape was freed"
      end

      def offs
        @offs ||= @tape[:offs].read_bytes(@tape[:count] * 4).unpack("V*")
      end

      def lens
        @lens ||= @tape[:lens].read_bytes(@tape[:count] * 4).unpack("V*")
      end

      # One bulk convert pass over the number spans (the engine's
      # materialize step — v2: parse records spans only). The strict
      # route's spans are grammar-validated at parse, so the bulk
      # call cannot fail; the lenient NUM records convert per record
      # with the deferred verdict.
      def bulk_convert!
        return if @ivals

        n = count
        ivp = ::FFI::MemoryPointer.new(:int64, n, true)
        dvp = ::FFI::MemoryPointer.new(:double, n, true)
        rc = ::Yeptris::FFI.yeptris_tape_convert(@tape.to_ptr, 0, n, ivp, dvp)
        # convert answers the NUMBER records converted (not the token
        # count) — SIZE_MAX would mean a span that does not re-scan
        expected = kinds.count { |k| k == :int || k == :float || k == :num }
        raise Error, "yeptris: strict tape convert failed (#{rc})" if rc != expected

        @ivals = ivp.read_bytes(n * 8).unpack("q<*")
        @dvals = dvp.read_bytes(n * 8).unpack("E*")
        # any integer text beyond int64: exact Bignum rebuilds from
        # the spans (the JSON.load parity contract, int_min is the
        # engine's materialize-time discovery)
        @exact_ints = @tape[:int_min] != 0
      end

      def number(i)
        case kinds[i]
        when :int
          bulk_convert!
          @exact_ints ? Integer(@source.byteslice(offs[i], lens[i]), 10) : @ivals[i]
        when :float
          bulk_convert!
          @dvals[i]
        else # :num — the lenient route's deferred classification
          convert_record!(i)
        end
      end

      # Per-record convert for a deferred NUM span: the engine scans,
      # validates, and classifies (shape 0 = integer, else float).
      def convert_record!(i)
        ivals = ::FFI::MemoryPointer.new(:int64)
        dvals = ::FFI::MemoryPointer.new(:double)
        converted = ::Yeptris::FFI.yeptris_tape_convert(
          @tape.to_ptr, i, i + 1, ivals, dvals
        )
        if converted != 1
          raise Error,
                "the number span at record #{i} " \
                "(#{@source.byteslice(offs[i], lens[i]).inspect}) is not a " \
                "valid number — the lenient route's deferred verdict"
        end

        text = @source.byteslice(offs[i], lens[i])
        if text.include?(".") || text.include?("e") || text.include?("E")
          dvals.read_double
        else
          ivals.read_int64
        end
      end
    end
  end
end
