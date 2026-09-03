# frozen_string_literal: true

require "date"
require "time"

module Yeptris
  # Recorder-driven Ruby materialization (TODO.impl/15 phase B).
  #
  # One bulk drain: the record array and string arena are read in two
  # calls, then a pure-Ruby stack machine walks fixed-layout records —
  # the FFI tax is O(chunks), never O(events). The DOM-walk
  # materializer (Node#to_ruby) stays for node-based use; this is the
  # Yeptris::YAML fast path.
  class Materializer
    RECORD_SIZE = 36 # YeptrisEventRecord layout (events.h, ABI-pinned)
    FIELDS = 12      # unpacked values per record
    RECORD_UNPACK = "C4V8" # type/style/flags/tag_id, line..tag_len

    STREAM_START = 1
    STREAM_END = 2
    DOCUMENT_START = 3
    DOCUMENT_END = 4
    SEQUENCE_START = 5
    SEQUENCE_END = 6
    MAPPING_START = 7
    MAPPING_END = 8
    SCALAR = 9
    ALIAS = 10

    EF_IMPLICIT = 1 << 2
    STYLE_PLAIN = 1

    # YeptrisTagId values (resolve.h; FFI mirrors them)
    TAG_STR = Yeptris::FFI::TAG_STR
    TAG_INT = Yeptris::FFI::TAG_INT
    TAG_FLOAT = Yeptris::FFI::TAG_FLOAT
    TAG_BOOL = Yeptris::FFI::TAG_BOOL
    TAG_NULL = Yeptris::FFI::TAG_NULL
    TAG_TIMESTAMP = Yeptris::FFI::TAG_TIMESTAMP
    TAG_MERGE = 9 # YEPTRIS_TAG_MERGE (resolve.h): a plain '<<' key

    INF_WORDS = {
      ".inf" => Float::INFINITY, ".Inf" => Float::INFINITY, ".INF" => Float::INFINITY,
      "+.inf" => Float::INFINITY, "+.Inf" => Float::INFINITY, "+.INF" => Float::INFINITY,
      "-.inf" => -Float::INFINITY, "-.Inf" => -Float::INFINITY, "-.INF" => -Float::INFINITY,
      ".nan" => Float::NAN, ".NaN" => Float::NAN, ".NAN" => Float::NAN,
    }.freeze
    SEXAGESIMAL_INT = /\A[-+]?[1-9][0-9_]*(:[0-5]?[0-9])+\z/
    SEXAGESIMAL_FLOAT = /\A[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+:[0-5]?[0-9]\.[0-9_]*\z/

    class << self
      # First document of the stream, or nil when the stream is empty.
      def load(yaml, schema: :compat_11)
        docs = load_stream(yaml, schema: schema)
        docs.empty? ? nil : docs.first
      end

      # Every document in the stream, in order.
      def load_stream(yaml, schema: :compat_11)
        new(schema: schema).materialize(yaml)
      end

      # The shared drain seam: one parse, records + arena read once,
      # ONE unpack into a flat Integer array (12 fields per record:
      # type style flags tag_id line col v_off v_len a_off a_len
      # t_off t_len). Both consumers ride it — the stack machine
      # (materialize) and the Psych::Parser dispatch loop.
      def drain(yaml, schema: :compat_11)
        rec = Yeptris::FFI.yeptris_recorder_new_ex(
          schema == :compat_11 ? Yeptris::FFI::SCHEMA_11_COMPAT : Yeptris::FFI::SCHEMA_12_CORE
        )
        begin
          status = Yeptris::FFI.yeptris_recorder_feed(rec, yaml, yaml.bytesize, 1)
          if status != Yeptris::FFI::OK
            raise Yeptris::ParseError,
                  "parse failed: #{Yeptris::FFI.last_error_message}"
          end
          count_p = ::FFI::MemoryPointer.new(:size_t)
          records = Yeptris::FFI.yeptris_recorder_records(rec, count_p)
          count = count_p.read_uint64
          arena_len = ::FFI::MemoryPointer.new(:size_t)
          arena_ptr = Yeptris::FFI.yeptris_recorder_arena(rec, arena_len)
          arena_len_v = arena_len.read_uint64
          arena = arena_ptr.null? || arena_len_v.zero? ? +"" : arena_ptr.read_bytes(arena_len_v)
          flat = records.read_bytes(count * RECORD_SIZE)
                     .unpack(RECORD_UNPACK * count)
          [flat, arena]
        ensure
          Yeptris::FFI.yeptris_recorder_free(rec)
        end
      end

      # The Ruby value of a scalar per schema — the ScalarScanner rule
      # set, spec-verified against Psych case by case. Only implicit
      # PLAIN scalars scan; quoting is the escape hatch.
      # The record's tag_id IS the resolver's verdict (the typing
      # SSOT): conversion by tag, Kernel#Integer/Float for the bytes —
      # no host-side grammar. Two Psych-quirk overrides where Psych's
      # scanner disagrees with the 1.1 resolver: single-char y/Y/n/N
      # are STRINGS in Psych (libyaml says bool), and values the
      # resolver tagged INT but Kernel rejects (mixed forms) fall back
      # through sexagesimal to String.
      PSYCH_TRUE = %w[y yes true on].freeze

      # '<<' merge: existing keys win; sequences merge in order.
      # Shared by the record walk and the value-stream walk.
      def merge_into(map, obj)
        case obj
        when Hash
          obj.each { |k, v| map[k] = v unless map.key?(k) }
        when Array
          obj.each { |e| merge_into(map, e) if e.is_a?(Hash) }
        end
      end

      def parse_timestamp(v)
        return Date.parse(v) unless v.match?(/[Tt ]\d/)

        # normalize the YAML 1.1 space forms onto iso8601 for
        # xmlschema: "2001-12-14 21:59:43.10 -05:00" ->
        # "2001-12-14T21:59:43.10-05:00" (Psych's scanner does the
        # same dance)
        Time.xmlschema(v.sub(/ (\d)/, 'T\1').sub(/ ([+-]\d)/, '\1'))
      rescue ArgumentError
        v
      end

      def scan_by_tag(value, tag_id, implicit)
        case tag_id
        when TAG_STR
          return value unless implicit

          value.start_with?(":") && !value.start_with?("::") &&
            value.length > 1 ? value[1..].to_sym : value
        when TAG_NULL then nil
        when TAG_BOOL
          return value if value.length == 1 # Psych: "y"/"n" stay Strings

          PSYCH_TRUE.include?(value.downcase)
        when TAG_INT
          int_or_string(value)
        when TAG_FLOAT
          float_or_string(value)
        when TAG_TIMESTAMP
          parse_timestamp(value)
        else
          value
        end
      end

      def int_or_string(value)
        Integer(value.tr("_", ""))
      rescue ArgumentError
        # the resolver said INT but Kernel disagrees (mixed form):
        # sexagesimal or back to String
        return sexagesimal(value) if SEXAGESIMAL_INT.match?(value) ||
                                     SEXAGESIMAL_FLOAT.match?(value)

        value
      end

      def float_or_string(value)
        return INF_WORDS[value] if INF_WORDS.key?(value)
        return value unless value.include?(".")

        # Psych's FLOAT: the exponent carries a mandatory sign —
        # "1e3" and "1.5e3" are Strings (resolver quirk override)
        return value if /[eE][^+-]/.match?(value)

        Float(value.tr("_", ""))
      rescue ArgumentError
        return sexagesimal(value) if SEXAGESIMAL_FLOAT.match?(value)

        value
      end

      private

      # Psych's scanner IS Kernel#Integer on the plain digits: Ruby
      # reads leading-zero strings as octal, rejects "018", takes
      # 0x/0b/bases — verified case by case against Psych.
      def sexagesimal(v)
        is_float = v.include?(".")
        total = 0
        v.split(":").each_with_index do |n, e|
          total += (is_float ? n.to_f : n.to_i) * (60**(e - 2).abs)
        end
        total
      end


    end

    def initialize(schema: :compat_11)
      @schema = schema
    end

    def materialize(yaml)
      yaml = yaml.read if yaml.respond_to?(:read)
      yaml = yaml.to_s
      flat, arena = Materializer.drain(yaml, schema: @schema)
      walk(flat, arena)
    end

    private

    # The stack machine: containers on a stack, a pending-key slot per
    # open mapping, anchors by name (first definition wins; an alias
    # yields the SAME Ruby object — identity preserved). Merge keys
    # (<<) resolve inline: existing keys win, sequences merge in
    # order — Psych load-time semantics.
    #
    # flat: one Integer per unpack field, 12 per record:
    # 0 type, 1 style, 2 flags, 3 tag_id, 4 line, 5 col, 6 value_off,
    # 7 value_len, 8 anchor_off, 9 anchor_len, 10 tag_off, 11 tag_len.
    def walk(flat, arena)
      docs = []
      stack = []
      anchors = {}
      pending_key = []
      pending_key_merge = []
      # per open container: the map to merge into when this container
      # closes (inline `<<:` values), nil otherwise
      merge_target = []

      # the arena is UTF-8 by construction (validated at parse), so
      # forcing its encoding ONCE makes every slice UTF-8 for free —
      # no per-scalar force_encoding
      arena.force_encoding(Encoding::UTF_8)
      # (each_slice DESTRUCTURING measured SLOWER than plain indexing
      # here: it allocates a 12-slot Array per record. Index away.)
      i = 0
      n = flat.length
      while i < n
        type = flat[i]
        case type
        when SCALAR
          # a plain, resolver-tagged '<<' (TAG_MERGE) merges; a
          # QUOTED '<<' is a literal key — Psych merges on the tag,
          # not the text
          tag_id = flat[i + 3]
          v = Materializer.scan_by_tag(
            arena[flat[i + 6], flat[i + 7]], tag_id, (flat[i + 2] & EF_IMPLICIT) != 0
          )
          l = flat[i + 9]
          anchors[arena[flat[i + 8], l]] = v if l != 0
          # place(): the scalar fast path inlined — the overwhelming
          # majority of events land here
          if stack.empty?
            docs[-1] = v
          else
            parent = stack.last
            if parent.is_a?(Hash)
              if (key = pending_key[-1]).nil?
                pending_key[-1] = v
                pending_key_merge[-1] = flat[i + 3] == TAG_MERGE
              else
                pending_key[-1] = nil
                if pending_key_merge[-1]
                  merge_into(parent, v)
                else
                  parent[key] = v
                end
              end
            else
              parent.push(v)
            end
          end
        when MAPPING_START
          h = {}
          l = flat[i + 9]
          anchors[arena[flat[i + 8], l]] = h if l != 0
          merge_target.push(place(docs, stack, pending_key, pending_key_merge, h))
          stack.push(h)
          pending_key.push(nil)
          pending_key_merge.push(nil)
        when SEQUENCE_START
          a = []
          l = flat[i + 9]
          anchors[arena[flat[i + 8], l]] = a if l != 0
          merge_target.push(place(docs, stack, pending_key, pending_key_merge, a))
          stack.push(a)
          pending_key.push(nil)
          pending_key_merge.push(nil)
        when ALIAS
          name = arena[flat[i + 6], flat[i + 7]]
          raise Yeptris::ParseError, "unknown anchor: #{name.inspect}" unless anchors.key?(name)

          place(docs, stack, pending_key, pending_key_merge, anchors[name])
        when MAPPING_END, SEQUENCE_END
          done = stack.pop
          pending_key.pop
          pending_key_merge.pop
          target = merge_target.pop
          merge_into(target, done) if target
        when DOCUMENT_START
          docs.push(nil)
        end
        i += FIELDS
      end
      docs
    end

    # Attaches obj: as the current document's root when nothing is
    # open, as a sequence entry, or as the pending mapping key/value.
    # Returns the merge TARGET when obj is a container placed under a
    # "<<" key — the caller defers the merge to the container's END
    # (an inline map's contents arrive after its start event); scalar
    # and alias merges apply immediately.
    def place(docs, stack, pending_key, pending_key_merge, obj)
      if stack.empty?
        docs[-1] = obj
        return nil
      end
      parent = stack.last
      if parent.is_a?(Hash)
        if pending_key.last.nil?
          pending_key[-1] = obj
          pending_key_merge[-1] = false
          return nil
        end
        key = pending_key.last
        pending_key[-1] = nil
        if pending_key_merge[-1]
          merge_into(parent, obj)
          parent
        else
          parent[key] = obj
          nil
        end
      else # Array
        parent.push(obj)
        nil
      end
    end

  end
end
