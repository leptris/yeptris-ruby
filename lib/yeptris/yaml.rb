# frozen_string_literal: true

# Self-sufficient (issue #95): the neutral surface is a valid entry
# point on its own — lutaml-model requires exactly this file.
require "yeptris"

module Yeptris
  # The neutral Ruby surface (the Psych-compat namespace arrives with
  # the recorder-driven Visitors in phase B; this is the yeptris-native
  # face users target first).
  module YAML
    autoload :Descriptor, "yeptris/yaml/descriptor"

    module_function

    # Loads the FIRST document of a YAML stream as native Ruby objects.
    # schema: :compat_11 selects Psych/libyaml implicit typing
    # (yes/no, 0o/octal, sexagesimal); :core_12 (default) is YAML 1.2.
    #
    # This surface keeps the Psych contract for EVERY input — including
    # JSON-shaped ones (`{"a": [1,]}` is legal flow YAML; `"1e3"` is a
    # Psych String). Strict RFC 8259 semantics live on Yeptris::JSON
    # (TODO.restructure/31): defaults follow proof, not benchmarks.
    def load(yaml, schema: :compat_11)
      yaml = Yeptris.read_input(yaml)
      yaml = yaml.to_s
      docs = _drain_all(yaml, schema)
      docs.empty? ? nil : docs.first
    end

    # Psych-semantics safe_load on the native surface (issue #69 —
    # the entry frameworks actually want): plain data only; a leaf
    # whose class is not permitted raises Yeptris::Psych::
    # DisallowedClass; aliases: false raises Yeptris::Psych::
    # AliasesError on alias use. Delegates to the compat namespace's
    # tree walk (correctness first; the fused drain comes later).
    def safe_load(yaml, permitted_classes: [], aliases: false, schema: :compat_11)
      yaml = Yeptris.read_input(yaml)
      Psych.safe_load(yaml.to_s, permitted_classes: permitted_classes, aliases: aliases)
    end

    # Every document in the stream, in order.
    def load_stream(yaml, schema: :compat_11)
      yaml = Yeptris.read_input(yaml)
      yaml = yaml.to_s
      _drain_all(yaml, schema)
    end

    # The Marshal fast path when the loaded libyeptris has it (>= 0.1.11
    # era builds), falling back to the columnar drain and finally the
    # record drain — one code path, the fastest the library offers.
    def _drain_all(yaml, schema)
      if FFI::MARSHAL
        result = ValueML.load_all_marshal(yaml, schema: schema, mode: :all)
        return result unless result.nil?
      end
      if FFI::COLUMNS
        ValueML.load_all_columns(yaml, schema: schema)
      else
        ValueML.load_all(yaml, schema: schema)
      end
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
      return nil if doc.nil? || doc.document_count.zero?

      doc.root(0)
    end

    # Serializes a Ruby object graph to YAML via the DOM builder
    # (TODO.impl/11 phase 3). Strings are emitted plain only when the
    # resolver round-trips them as strings — everything else takes a
    # quoted style, so dump(load(x)) == x for the scalar types.
      def dump(obj, canonical: false, header: false)
      BulkBuilder.dump(obj, canonical: canonical, header: header)
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
      STYLE_SQ = 2
      STYLE_DQ = 3
      STYLE_LIT = 4
      BUILD_TAG = Yeptris::FFI::BUILD_TAG

      module_function

      # Psych's exact timestamp spelling (format_time, #300): space
      # separated, nanosecond width, Z for UTC — iso8601 diverged
      def time_text(t)
        t.utc? ? t.strftime("%Y-%m-%d %H:%M:%S.%9N Z") : t.strftime("%Y-%m-%d %H:%M:%S.%9N %:z")
      end

      # Psych's float spelling (#290): Infinity/NAN ride the YAML words,
      # not Ruby's to_s (which prints "Infinity"/"NaN" — a STRING on
      # reload)
      def float_text(f)
        return ".nan" if f.respond_to?(:nan?) && f.nan?
        case (inf = f.infinite?)
        when 1 then ".inf"
        when -1 then "-.inf"
        else f.to_s
        end
      end

      # container entries are constant bytes — no pack per op
      MAP_ENTRY = [Yeptris::FFI::BUILD_MAP, 0, 0, 0].pack("CCx2VV").freeze
      SEQ_ENTRY = [Yeptris::FFI::BUILD_SEQ, 0, 0, 0].pack("CCx2VV").freeze
      END_ENTRY = [Yeptris::FFI::BUILD_END, 0, 0, 0].pack("CCx2VV").freeze
      CONT_ENTRY = { Yeptris::FFI::BUILD_MAP => MAP_ENTRY,
                     Yeptris::FFI::BUILD_SEQ => SEQ_ENTRY,
                     Yeptris::FFI::BUILD_END => END_ENTRY }.freeze

      def dump(obj, canonical: false, header: false)
        parts = []
        blob = String.new(encoding: Encoding::BINARY)
        off = [0]
        # one pack per SCALAR; containers reuse frozen constants
        emit = lambda do |op, style, o, len|
          parts << (o.zero? && len.zero? && style.zero? ? CONT_ENTRY[op] :
                      [op, style, o, len].pack("CCx2VV"))
        end
        place(obj, emit, blob, off, {})
        doc = Document.create
        buf = ::FFI::MemoryPointer.from_string(parts.join)
        bblob = ::FFI::MemoryPointer.from_string(blob)
        rc = doc.build_entries(buf, parts.length, bblob, blob.bytesize)
        raise DumpError, "document_build failed: #{rc}" unless rc == FFI::OK
        doc.serialize(canonical: canonical, explicit_doc_start: header)
      ensure
        doc&.free
      end

      def place(obj, emit, blob, off, seen)
        case obj
        when Hash
          cycle_guard(obj, seen) do
            emit.call(MAP, 0, 0, 0)
            obj.each do |k, v|
              # Symbol keys emit as bare ":k" plain — the compat
              # reader resolves them back to Symbols; string keys
              # ride the visit_String rules like any other scalar
              # Symbol keys emit as bare ":k" plain — the compat
              # reader resolves them back to Symbols; Integer/Float/
              # bool keys ride plain like their values (Psych emits
              # 1: unquoted — #290 family 5); string keys ride the
              # visit_String rules like any other scalar; NIL keys
              # ride Psych's explicit-`!` empty-scalar form
              # (#300 family 2)
              if k.nil?
                scalar("", STYLE_SQ, emit, blob, off)
                emit.call(BUILD_TAG, 0, off[0], 1)
                blob << "!"
                off[0] += 1
              elsif k.is_a?(Symbol)
                scalar(":#{k}", STYLE_PLAIN, emit, blob, off)
              elsif k.is_a?(String)
                place(k, emit, blob, off, seen)
              else
                scalar(k.to_s, STYLE_PLAIN, emit, blob, off)
              end
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
        when String
          if obj.encoding == ::Encoding::ASCII_8BIT && !obj.ascii_only?
            # #168: psych visit_String's binary branch — strict base64
            # + the short !binary tag + literal style (Builder
            # build_string carries the same branch; the tagged-literal
            # writer keeps the block form)
            scalar([obj].pack("m0"), STYLE_LIT, emit, blob, off)
            emit.call(BUILD_TAG, 0, off[0], 7)
            blob << "!binary"
            off[0] += 7
          else
            scalar(obj, STYLE_BY_NAME[string_style(obj)], emit, blob, off)
          end
        when Symbol then scalar(":#{obj}", STYLE_PLAIN, emit, blob, off)
        when Integer then scalar(obj.to_s, STYLE_PLAIN, emit, blob, off)
        when Float then scalar(float_text(obj), STYLE_PLAIN, emit, blob, off)
        when true, false then scalar(obj.to_s, STYLE_PLAIN, emit, blob, off)
        when nil then scalar("", STYLE_PLAIN, emit, blob, off)
        when Time then scalar(time_text(obj), STYLE_PLAIN, emit, blob, off)
        when Date then scalar(obj.iso8601, STYLE_PLAIN, emit, blob, off)
        else
          raise DumpError,
                "cannot dump #{obj.class}: unsupported object " \
                "(custom to_yaml support lands with the Psych Visitors)"
        end
      end

      def scalar(text, style, emit, blob, off)
        # a BINARY blob absorbs any String bytewise (String#<< on
        # ASCII-8BIT is compatible with every encoding) — the old
        # text.b made a throwaway copy of every scalar before the
        # blob's own copy
        emit.call(SCALAR, style, off[0], text.bytesize)
        blob << text
        off[0] += text.bytesize
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
      # the fast lane consults the reshape table per string: an Array
      # scan of 36 words was ~a third of the whole dump walk
      RESHAPES_SET = RESHAPES.each_with_object({}) { |w, h| h[w] = true }.freeze

      SAFE_WORD = /\A[A-Za-z][A-Za-z0-9_\-.\/ ]*\z/

      def plain_string?(s)
        # fast lane: letter-started, safe characters incl. spaces — no
        # number/timestamp/indicator shape is possible; only the
        # reshape words need the set lookup
        if SAFE_WORD.match?(s) && !s.end_with?(" ") && !RESHAPES_SET[s]
          return true
        end
        return false if s.empty? || s != s.strip
        return false if s.match?(/[\n\t]/)
        c = s[0]
        return false if "#,[]{}&*!|>'\"%@`".include?(c)
        return false if "-?:".include?(c) && (s.length == 1 || s[1] =~ /[ \t]/)
        return false if s.include?(": ") || s.end_with?(":") || s.include?(" #")
        return false if RESHAPES_SET[s]
        # compat's float grammar REQUIRES the dot ("1e3" re-reads as a
        # String and may dump plain); ints/sexagesimals still reshape.
        # psych's FLOAT has no trailing [.:] group — "1.2.3" is a
        # String and dumps plain (pinned by spec/yaml_spec.rb)
        return false if s.match?(/\A[-+]?(0|[1-9][0-9_]*)(:[0-5]?[0-9])+\z/)
        return false if s.match?(/\A[-+]?(0|[1-9][0-9_]*)\z/)
        return false if s.match?(/\A[-+]?[0-9][0-9_]*\.[0-9_]*([eE][-+]?[0-9]+)?\z/)
        return false if s.match?(/\A[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+\.[0-9_]*\z/)
        return false if s.match?(/\A[-+]?(0x[0-9a-fA-F_]+|0b[01_]+|0o?[0-7_]+)\z/)
        return false if s.match?(/\A[-+]?\.(inf|Inf|INF)\z|\A\.(nan|NaN|NAN)\z/)
        !s.match?(/\A\d{4}-\d\d?-\d\d?([Tt ]|$)/)
      end

      # Psych parity (psych yaml_tree#visit_String) — the quoting
      # decision for a String, in psych's own order:
      #   y/Y/n/N (the 1.1 bool words psych double-quotes) → double
      #   a leading non-word character, no " anywhere          → double
      #   a 1.1 bad-octal shape (0[0-7]*[89])                 → single
      #   re-loads as something other than String (plain_string?
      #   rejects the 1.1 number/bool/null/timestamp shapes)   → single
      #   needs escapes (control bytes, multiline)             → double
      #   otherwise                                            → plain
      # psych's literal/folded/binary forms and its !!str tag for
      # "<<" are follow-ups; those strings double-quote today.
      STYLE_BY_NAME = { plain: STYLE_PLAIN, single: STYLE_SQ, double: STYLE_DQ,
                        literal: STYLE_LIT }.freeze

      def string_style(s)
        # psych's visit_String: any interior newline rides a literal
        # block (the C writer's libyaml indicator rules render it) —
        # first, exactly as psych orders it (#290 family 4)
        return :literal if s.match?(/\n(?!\z)/)
        return :double if s == "y" || s == "Y" || s == "n" || s == "N"
        return :double if !s.empty? && !s.include?('"') && s.match?(/\A[^[:word:]]/)
        return :single if s.match?(/\A0[0-7]*[89]/)
        return :plain if plain_string?(s)
        return :double if s.each_byte.any? { |b| b < 0x20 || b == 0x7f }
        :single
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
        when Integer then new_scalar(doc, obj.to_s)
        when Float then new_scalar(doc, BulkBuilder.float_text(obj))
        when true, false then new_scalar(doc, obj.to_s)
        when nil then new_scalar(doc, "")
        when Time then new_scalar(doc, BulkBuilder.time_text(obj))
        when Date then new_scalar(doc, obj.iso8601)
        else
          raise DumpError,
                "cannot dump #{obj.class}: unsupported object " \
                "(custom to_yaml support lands with the Psych Visitors)"
        end
      end

      def build_map(doc, h, seen)
        cycle_guard(h, seen) do
          m = doc.new_mapping
          h.each do |k, v|
            if k.nil?
              key_node = doc.new_scalar("", :single_quoted)
              key_node.set_tag("!")
              m.map_add_node(key_node, build(doc, v, seen))
            else
              m.map_add(key_text(k), build(doc, v, seen))
            end
          end
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

      # One quoting table (BulkBuilder.string_style — psych's
      # visit_String matrix) serves both builders; this side carries
      # the style onto the per-node DOM.
      def build_string(doc, s)
        # psych 5.5 visit_String's binary branch, verbatim: an
        # ASCII-8BIT string with non-ASCII bytes emits as strict base64
        # (pack('m0'), never wrapped) under the short !binary tag with
        # literal style — the writer keeps the block form for tagged
        # literals (#168). BOTH dump paths converge here (the top-level
        # scalar fast route and the YAMLTree visitor).
        if s.encoding == ::Encoding::ASCII_8BIT && !s.ascii_only?
          bin = new_scalar(doc, [s].pack("m0"), :force_lit)
          bin.set_tag("!binary")
          return bin
        end
        case BulkBuilder.string_style(s)
        when :single then new_scalar(doc, s, :force_str_sq)
        when :double then new_scalar(doc, s, :force_str)
        when :literal then new_scalar(doc, s, :force_lit)
        else new_scalar(doc, s)
        end
      end

      def key_text(k)
        k = ":#{k}" if k.is_a?(Symbol)
        k.to_s
      end

      def new_scalar(doc, text, mode = nil)
        doc.new_scalar(text.to_s,
                       mode == :force_str ? :double_quoted :
                       mode == :force_str_sq ? :single_quoted :
                       mode == :force_lit ? :literal : :plain)
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
