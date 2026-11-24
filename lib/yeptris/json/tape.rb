# frozen_string_literal: true

# The JSON tape view (yeptris/tape.h; TODO.restructure/85,
# yeptris-ruby#411): the compact columnar face the C binding has —
# ONE strict (or lenient) walk appends ONE record per token into
# three bulk columns (kind bytes, span offsets, span lengths), no DOM
# nodes, no tree. Strings stay RAW spans into the caller's source
# (escapes untouched); numbers record SPANS ONLY and materialize
# through {#int_at}/{#float_at}/{#convert!} (the simdjson deferred
# contract).
#
#   tape = Yeptris::JSON::Tape.parse('{"a":[1,2.5,"x"]}')
#   tape.count            # => 9 (records; record 0 is the DOC boundary)
#   tape.kind(1)          # => :map_open
#   tape.int_at(3)        # => 1
#   tape.string_at(6)     # => "x"
#
# The lenient route (+lenient:+) keeps every structural check at
# parse but defers NUMBER grammar to conversion — "1.2.3" parses as a
# :num record and rejects at {#convert!}/{#number_at}, exactly where
# simdjson's deferred parse fails.
#
# The spans borrow the caller's source: keep the source string alive
# for the tape's lifetime (the tape retains its own reference).
class Yeptris::JSON::Tape
  include Enumerable

  # The kinds column's symbols (tape.h's ABI-pinned order). :num only
  # appears on the lenient route.
  KIND_SYMBOLS = {
    0 => :doc, 1 => :null, 2 => :true, 3 => :false,
    4 => :int, 5 => :float, 6 => :str,
    7 => :seq_open, 8 => :map_open, 9 => :close, 10 => :num,
  }.freeze
  private_constant :KIND_SYMBOLS

  SPAN_KINDS = %i[int float str num].freeze
  private_constant :SPAN_KINDS

  # One tape record: the token's +index+, its +kind+ symbol, and — for
  # span kinds — the +off+/+len+ of the raw span in the source.
  # Container records carry their link in +off+ (see {#match}).
  Record = Struct.new(:index, :kind, :off, :len)

  class << self
    # Parses strict JSON into the tape (+lenient:+ opts into the
    # deferred-number route). Raises Yeptris::JSON::ParseError on
    # invalid input.
    def parse(source, lenient: false)
      src = ::Yeptris.read_input(source).to_s
      tape = ::Yeptris::FFI::JsonTape.new
      rc =
        if lenient
          unless ::Yeptris::FFI::TAPE_LENIENT
            raise ::Yeptris::Error,
                  "yeptris: the lenient tape route needs libyeptris 0.6.9+; " \
                  "the loaded library predates it. Update the engine library."
          end
          ::Yeptris::FFI.yeptris_parse_json_tape_lenient(src, src.bytesize, tape)
        else
          ::Yeptris::FFI.yeptris_parse_json_tape(src, src.bytesize, tape)
        end
      raise ::Yeptris::JSON::ParseError,
            "tape parse failed: #{::Yeptris::FFI.last_error_message}" unless rc == ::Yeptris::FFI::OK

      obj = allocate
      obj.setup(src, tape)
      obj
    end

    # Block form: the tape frees when the block exits (valid or not).
    def open(source, lenient: false)
      tape = parse(source, lenient: lenient)
      begin
        yield tape
      ensure
        tape.free
      end
    end

    # The caller-owned-handle finalizer: the proc holds the FFI
    # struct itself (its memory IS the C handle) plus the shared
    # Freed flag so an explicit #free never double-frees.
    def finalize(struct, freed)
      proc do
        next if freed.state == :freed

        freed.state = :freed
        ::Yeptris::FFI.yeptris_tape_free(struct)
      end
    end
  end

  # Shared between the instance and its finalizer.
  Freed = Struct.new(:state) # :alive | :freed

  SIZE_MAX = (1 << (::FFI.type_size(:size_t) * 8)) - 1

  # @api private — wired by .parse; a bare FFI struct is not a caller
  # surface.
  def setup(source, tape)
    @source = source # spans borrow it: retained for the tape's life
    @tape = tape
    @freed = Freed.new(:alive)
    materialize_columns!
    # the column pointers (C-owned; valid until #free) — every read
    # goes through check_range!, which refuses a freed tape
    @kinds = @tape[:kinds]
    @offs = @tape[:offs]
    @lens = @tape[:lens]
    # the interleaved-record finalizer must keep the struct memory the
    # C handle reads alive past the wrapper — the proc holds the
    # struct itself (a caller-owned handle: the C side holds no Ruby
    # reference, so there is no wrapper race to avoid).
    ObjectSpace.define_finalizer(self, self.class.finalize(@tape, @freed))
  end

  # Record count (record 0 is the DOC boundary; records start at 1).
  def count
    @tape[:count]
  end

  # The record's kind symbol (see KIND_SYMBOLS).
  def kind(i)
    check_range!(i)
    KIND_SYMBOLS.fetch(@kinds.get_uint8(i))
  end

  # The record's span start (span kinds), or the container link (see
  # {#match}) — the raw column value.
  def off(i)
    check_range!(i)
    @offs.get_uint32(i * 4)
  end

  # The record's span length (0 for non-span records).
  def len(i)
    check_range!(i)
    @lens.get_uint32(i * 4)
  end

  # [off, len] for a span-kind record; nil for the others.
  def span(i)
    return nil unless SPAN_KINDS.include?(kind(i))

    [off(i), len(i)]
  end

  # The container link: the matching close's index for :seq_open /
  # :map_open, the matching open's index for :close; nil for the
  # other kinds.
  def match(i)
    k = kind(i)
    return nil unless %i[seq_open map_open close].include?(k)

    off(i)
  end

  # The record's RAW span bytes (a BINARY copy — escapes untouched,
  # the C contract), or nil for non-span records.
  def slice(i)
    k = kind(i)
    return nil unless SPAN_KINDS.include?(k)

    @source.byteslice(off(i), len(i)).force_encoding(Encoding::BINARY)
  end

  # The :str record's decoded UTF-8 text (JSON escapes decoded — the
  # same kernel Yeptris::JSON.load materializes with).
  def string_at(i)
    raise ::ArgumentError,
          "record #{i} is #{kind(i)}, not a string span" unless kind(i) == :str

    off, len = span(i)
    len.zero? ? String.new(encoding: Encoding::UTF_8) : ::Yeptris::JSON.decode_span(@source, off, len)
  end

  # The :int record's value. A span beyond int64 materializes exactly
  # from its text (Bignum — the JSON.parse parity json.rb carries).
  def int_at(i)
    raise ::ArgumentError,
          "record #{i} is #{kind(i)}, not an int span" unless kind(i) == :int

    # the C writes are RECORD-indexed (parallel to the tape, not
    # window-relative — tape.h), so the buffer spans [0, i]
    iv = ::FFI::MemoryPointer.new(:int64, i + 1, true)
    rc = ::Yeptris::FFI.yeptris_tape_convert(@tape, i, i + 1, iv, nil)
    raise number_error(i) if rc == SIZE_MAX

    return Integer(slice(i), 10) unless @tape[:int_min].zero?

    iv.get_int64(8 * i)
  end

  # The :float record's value.
  def float_at(i)
    raise ::ArgumentError,
          "record #{i} is #{kind(i)}, not a float span" unless kind(i) == :float

    dv = ::FFI::MemoryPointer.new(:double, i + 1, true)
    rc = ::Yeptris::FFI.yeptris_tape_convert(@tape, i, i + 1, nil, dv)
    raise number_error(i) if rc == SIZE_MAX

    dv.get_double(8 * i)
  end

  # A lenient-route :num record's value — the conversion IS the
  # authority: the span re-scans now and classifies int/float; a
  # malformed span ("1.2.3") raises ParseError here, not at parse
  # (the deferred contract).
  def number_at(i)
    raise ::ArgumentError,
          "record #{i} is #{kind(i)}, not a deferred number span" unless kind(i) == :num

    iv = ::FFI::MemoryPointer.new(:int64, i + 1, true)
    dv = ::FFI::MemoryPointer.new(:double, i + 1, true)
    dv.write_array_of_double([Float::NAN] * (i + 1)) # untouched slots stay untouched: NaN marks the float lane
    rc = ::Yeptris::FFI.yeptris_tape_convert(@tape, i, i + 1, iv, dv)
    raise number_error(i) if rc == SIZE_MAX

    dv.get_double(8 * i).nan? ? iv.get_int64(8 * i) : dv.get_double(8 * i)
  end

  # ONE bulk conversion of every number record in [from, to): the
  # materialization economy the columnar consumers use. Returns the
  # number records converted. Raises ParseError when a span does not
  # re-scan as a number (possible only on the lenient route).
  def convert!(from = 0, to = count)
    check_range!(from) unless from.zero?
    check_range!(to - 1) unless to.zero?
    raise ::ArgumentError, "from (#{from}) must be <= to (#{to})" if from > to

    # the C writes are record-indexed: the buffers span [0, to)
    ivp = ::FFI::MemoryPointer.new(:int64, to, true)
    dvp = ::FFI::MemoryPointer.new(:double, to, true)
    rc = ::Yeptris::FFI.yeptris_tape_convert(@tape, from, to, ivp, dvp)
    raise number_error(from) if rc == SIZE_MAX

    rc
  end

  # Yields one {Record} per tape record (Enumerable over the tape).
  def each
    return enum_for(:each) unless block_given?

    count.times do |i|
      k = kind(i)
      span_kind = SPAN_KINDS.include?(k)
      link = span_kind || %i[seq_open map_open close].include?(k)
      yield Record.new(i, k, link ? off(i) : nil, span_kind ? len(i) : nil)
    end
  end

  def ensure_alive!
    raise ::Yeptris::FreedError, "tape is freed" if @freed.state == :freed
  end

  def free
    return if @freed.state == :freed

    @freed.state = :freed
    ObjectSpace.undefine_finalizer(self)
    ::Yeptris::FFI.yeptris_tape_free(@tape)
  end

  def freed?
    @freed.state == :freed
  end

  private

  def check_range!(i)
    ensure_alive!
    raise ::IndexError, "record #{i} out of range (count #{count})" if i.negative? || i >= count
  end

  def number_error(i)
    ::Yeptris::JSON::ParseError.new(
      "tape: record #{i} does not scan as a number (#{slice(i).inspect})"
    )
  end

  # The interleaved-records route (lenient, engine 0.6.34+) stores the
  # data in recs and materializes the compat columns lazily — the FFI
  # consumer reads the columns, so raise them once at parse.
  def materialize_columns!
    return unless @tape[:_rec_primary] != 0

    unless ::Yeptris::FFI::TAPE_COLUMNS
      raise ::Yeptris::Error,
            "yeptris: this libyeptris predates the interleaved tape " \
            "records' column materializer. Update the engine library."
    end
    return if ::Yeptris::FFI.yeptris_tape_columns(@tape).zero?

    raise ::Yeptris::Error, "tape: column materialization failed"
  end
end
