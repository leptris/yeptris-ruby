# frozen_string_literal: true

module Yeptris
  # The neutral Ruby surface (the Psych-compat namespace arrives with
  # the recorder-driven Visitors in phase B; this is the yeptris-native
  # face users target first).
  module YAML
    module_function

    # Loads the FIRST document of a YAML stream as native Ruby objects.
    # schema: :compat_11 selects Psych/libyaml implicit typing
    # (yes/no, 0o/octal, sexagesimal); :core_12 (default) is YAML 1.2.
    def load(yaml, schema: :compat_11)
      Materializer.load(yaml, schema: schema)
    end

    # Every document in the stream, in order.
    def load_stream(yaml, schema: :compat_11)
      Materializer.load_stream(yaml, schema: schema)
    end

    # The Psych-suite port's spelling (spec/psych/): compat typing.
    def parse_yaml(yaml)
      load(yaml)
    end

    def load_file(path, schema: :compat_11)
      File.open(path, "rb") { |f| load(f, schema: schema) }
    end

    # Parses without materializing: the first document's root Node.
    def parse(yaml, schema: :core_12)
      doc = Document.parse(yaml, schema: schema)
      return nil if doc.document_count.zero?

      doc.root(0)
    end

    # Serializes a Ruby object graph to YAML via the DOM builder
    # (TODO.impl/11 phase 3). Strings are emitted plain only when the
    # resolver round-trips them as strings — everything else takes a
    # quoted style, so dump(load(x)) == x for the scalar types.
    def dump(obj, canonical: false)
      BulkBuilder.dump(obj, canonical: canonical)
    end


    # The dump-side mirror of the Materializer's bulk drain (TODO.impl
    # 15 phase D): the tree walks into one flat entry array plus one
    # string blob, and yeptris_document_build raises the DOM in a
    # SINGLE FFI call — per-node FFI is gone. Same semantics as the
    # per-node Builder it replaces (cycle refusal, :symbol scalars,
    # Date/Time iso8601, plain-only-when-it-round-trips strings),
    # with plain_string? pinned to the resolver by a differential
    # spec.
    module BulkBuilder
      SCALAR = Yeptris::FFI::BUILD_SCALAR
      SEQ = Yeptris::FFI::BUILD_SEQ
      MAP = Yeptris::FFI::BUILD_MAP
      STOP = Yeptris::FFI::BUILD_END
      STYLE_PLAIN = 1
      STYLE_DQ = 3

      module_function

      def dump(obj, canonical: false)
        parts = []
        blob = +""
        off = [0]
        # one pack per entry: CC (op, style) x2 (reserved) VV (off, len)
        emit = lambda do |op, style, o, len|
          parts << [op, style, o, len].pack("CCx2VV")
        end
        place(obj, emit, blob, off, {})
        doc = Document.create
        buf = ::FFI::MemoryPointer.from_string(parts.join)
        bblob = ::FFI::MemoryPointer.from_string(blob)
        rc = doc.build_entries(buf, parts.length, bblob, blob.bytesize)
        raise DumpError, "document_build failed: #{rc}" unless rc == FFI::OK
        doc.serialize(canonical: canonical)
      ensure
        doc&.free
      end

      def place(obj, emit, blob, off, seen)
        case obj
        when Hash
          cycle_guard(obj, seen) do
            emit.call(MAP, 0, 0, 0)
            obj.each do |k, v|
              place(key_text(k), emit, blob, off, seen)
              place(v, emit, blob, off, seen)
            end
            emit.call(STOP, 0, 0, 0)
          end
        when Array
          cycle_guard(obj, seen) do
            emit.call(SEQ, 0, 0, 0)
            obj.each { |e| place(e, emit, blob, off, seen) }
            emit.call(STOP, 0, 0, 0)
          end
        when String then scalar(obj, plain_string?(obj), emit, blob, off)
        when Symbol then scalar(":#{obj}", true, emit, blob, off)
        when Integer, Float then scalar(obj.to_s, true, emit, blob, off)
        when true, false then scalar(obj.to_s, true, emit, blob, off)
        when nil then scalar("null", true, emit, blob, off)
        when Date, Time then scalar(obj.iso8601, true, emit, blob, off)
        else
          raise DumpError,
                "cannot dump #{obj.class}: unsupported object " \
                "(custom to_yaml support lands with the Psych Visitors)"
        end
      end

      def scalar(text, plain, emit, blob, off)
        bytes = text.b
        emit.call(SCALAR, plain ? STYLE_PLAIN : STYLE_DQ, off[0], bytes.bytesize)
        blob << bytes
        off[0] += bytes.bytesize
      end

      def key_text(k)
        k = ":#{k}" if k.is_a?(Symbol)
        k.to_s
      end

      # A plain scalar that the compat resolver re-reads as STR stays
      # plain; anything resolvable (null/bool words, int/float/timestamp
      # shapes, indicators, merge '<<') takes double quotes so the
      # reparse yields String again. Pinned to the C resolver's own
      # verdicts by the differential spec (spec/yaml_spec.rb).
      RESHAPES = %w[~ null Null NULL y Y yes Yes YES n N no No NO true True
                    TRUE false False FALSE on On ON off Off OFF <<].freeze

      def plain_string?(s)
        return false if s.empty? || s != s.strip
        return false if s.match?(/[\n\t]/)
        c = s[0]
        return false if "#,[]{}&*!|>'\"%@`".include?(c)
        return false if "-?:".include?(c) && (s.length == 1 || s[1] =~ /[ \t]/)
        return false if s.include?(": ") || s.end_with?(":") || s.include?(" #")
        return false if RESHAPES.include?(s)
        # compat's float grammar REQUIRES the dot ("1e3" re-reads as a
        # String and may dump plain); ints/sexagesimals still reshape
        return false if s.match?(/\A[-+]?(0|[1-9][0-9_]*)(:[0-5]?[0-9])+\z/)
        return false if s.match?(/\A[-+]?(0|[1-9][0-9_]*)\z/)
        return false if s.match?(/\A[-+]?[0-9][0-9_]*\.[0-9_]*([eE][-+]?[0-9]+)?([.:][0-9_:.]*)?\z/)
        return false if s.match?(/\A[-+]?(0x[0-9a-fA-F_]+|0b[01_]+|0o?[0-7_]+)\z/)
        return false if s.match?(/\A[-+]?\.(inf|Inf|INF)\z|\A\.(nan|NaN|NAN)\z/)
        !s.match?(/\A\d{4}-\d\d?-\d\d?([Tt ]|$)/)
      end

      def cycle_guard(obj, seen)
        id = obj.object_id
        raise DumpError, "cycle detected: cannot dump recursive #{obj.class}" if seen[id]

        seen[id] = true
        out = yield
        seen.delete(id)
        out
      end
    end

    # From-scratch builder over the public construction API.
    module Builder
      module_function

      def build(doc, obj, seen = {})
        case obj
        when Hash then build_map(doc, obj, seen)
        when Array then build_seq(doc, obj, seen)
        when String then build_string(doc, obj)
        when Symbol then new_scalar(doc, ":#{obj}")
        when Integer, Float then new_scalar(doc, obj.to_s)
        when true, false then new_scalar(doc, obj.to_s)
        when nil then new_scalar(doc, "null")
        when Date, Time then new_scalar(doc, obj.iso8601)
        else
          raise DumpError,
                "cannot dump #{obj.class}: unsupported object " \
                "(custom to_yaml support lands with the Psych Visitors)"
        end
      end

      def build_map(doc, h, seen)
        cycle_guard(h, seen) do
          m = doc.new_mapping
          h.each { |k, v| m.map_add(key_text(k), build(doc, v, seen)) }
          m
        end
      end

      def build_seq(doc, a, seen)
        cycle_guard(a, seen) do
          s = doc.new_sequence
          a.each { |e| s.seq_add(build(doc, e, seen)) }
          s
        end
      end

      # A plain scalar that re-resolves to STR stays plain (nice
      # round-trips); anything ambiguous is double-quoted so the
      # reparse yields String again.
      def build_string(doc, s)
        n = new_scalar(doc, s)
        n.tag_id == :str ? n : new_scalar(doc, s, :force_str)
      end

      def key_text(k)
        k = ":#{k}" if k.is_a?(Symbol)
        k.to_s
      end

      def new_scalar(doc, text, mode = nil)
        doc.new_scalar(text.to_s,
                       mode == :force_str ? :double_quoted : :plain)
      end

      def cycle_guard(obj, seen)
        id = obj.object_id
        raise DumpError, "cycle detected: cannot dump recursive #{obj.class}" if seen[id]

        seen[id] = true
        out = yield
        seen.delete(id)
        out
      end
    end
  end
end
