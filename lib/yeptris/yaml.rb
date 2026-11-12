# frozen_string_literal: true

# The BulkBuilder's `when Date` must not depend on the caller loading
# stdlib's date (issue #289: a clean `require "yeptris"` raised NameError
# before the DumpError branch could run). Psych requires date the same way.
require "date"

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
    # The validation keywords (#882) check BEFORE loading and raise
    # Yeptris::Validation::Error carrying the diagnostics on invalid
    # input: `validate:` rides the engine's schema-family walk (true
    # rides :core_12 — the 1.2 families are the validation families;
    # or an explicit :core_12 / :json_12), `json_schema:` validates
    # against JSON Schema draft 2020-12 (schema bytes or a compiled
    # Yeptris::Validation::Schema).
    #
    # This surface keeps the Psych contract for EVERY input — including
    # JSON-shaped ones (`{"a": [1,]}` is legal flow YAML; `"1e3"` is a
    # Psych String). Strict RFC 8259 semantics live on Yeptris::JSON
    # (TODO.restructure/31): defaults follow proof, not benchmarks.
    def load(yaml, schema: :compat_11, validate: nil, json_schema: nil)
      yaml = Yeptris.read_input(yaml)
      yaml = yaml.to_s
      _assert_valid(yaml, validate, json_schema) if validate || json_schema
      docs = _drain_all(yaml, schema)
      docs.empty? ? nil : docs.first
    end

    # The validation face (#882): every diagnostic the engine reports,
    # as plain Yeptris::Validation::Diagnostic values (empty array =
    # valid). Default is the engine's core-family walk; `json_schema:`
    # switches to JSON Schema draft 2020-12 (bytes or a compiled
    # Yeptris::Validation::Schema), `validate:` picks the schema family
    # explicitly (:core_12 / :json_12). Every document of the stream is
    # validated; paths are root-relative per document.
    def validate(yaml, validate: true, json_schema: nil)
      yaml = Yeptris.read_input(yaml)
      _validation_call(yaml.to_s, validate, json_schema)
    end

    # The boolean posture of validate: true when the engine reports no
    # diagnostics.
    def valid?(yaml, validate: true, json_schema: nil)
      validate(yaml, validate: validate, json_schema: json_schema).empty?
    end

    # The load-side gate: raises Yeptris::Validation::Error carrying
    # the diagnostics when the input is invalid; silent otherwise.
    def _assert_valid(yaml, validate, json_schema)
      diags = _validation_call(yaml, validate, json_schema)
      raise Validation::Error, diags unless diags.empty?
    end

    def _validation_call(yaml, validate, json_schema)
      if json_schema
        Validation.validate_schema(yaml, json_schema)
      else
        # `validate: true` rides :core_12 — the family walk has no
        # :compat_11 face (the engine rejects it; resolve schemas are
        # not validation families).
        Validation.validate_family(yaml, schema: validate == true ? :core_12 : validate)
      end
    end
    private_class_method :_validation_call
    private_class_method :_assert_valid

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

    # Every document in the stream, in order (the multi-document stream
    # API, yeptris#881 — Psych's load_stream parity). Document boundary
    # detection follows the engine's stream parse: explicit --- / ...
    # markers, implicit documents after a ... terminator, and empty
    # documents — nil elements, exactly what Psych yields for them.
    #
    # errors: :raise (default) raises Yeptris::ParseError on the first
    # bad document — psych's behavior (a stream parse cannot resume
    # past it). errors: :collect never raises for a bad document: the
    # text re-walks at marker boundaries (see _stream_slices) and the
    # bad document's position carries a Yeptris::ParseError marker
    # (skip with results.grep(Yeptris::ParseError)). A stream that
    # parses whole collects to the same plain document array as :raise.
    #
    # With a block, every element — documents and, under :collect,
    # error markers — is yielded in order; the array is returned.
    #
    # The validation keywords (#882) run the whole stream BEFORE
    # loading (the same shapes as load: `validate:` family walk /
    # `json_schema:` JSON Schema 2020-12) and raise
    # Yeptris::Validation::Error on any diagnostics. The engine's
    # report is flat across the stream — diagnostics carry no
    # per-document index (streaming validation is future work, #885) —
    # so the verdict is whole-stream by construction.
    def load_stream(yaml, schema: :compat_11, errors: :raise, validate: nil,
                    json_schema: nil, &block)
      unless %i[raise collect].include?(errors)
        raise ArgumentError, "errors: must be :raise or :collect (got #{errors.inspect})"
      end

      yaml = Yeptris.read_input(yaml)
      yaml = yaml.to_s
      _assert_valid(yaml, validate, json_schema) if validate || json_schema
      docs =
        begin
          docs = _drain_all(yaml, schema)
          # The value drain emits a nil record even for a stream with
          # ZERO documents ("", a blank line, a comment) — stdlib's
          # load_stream answers zero documents there, and the corner
          # must not mask a real empty document ("---\n" IS [nil]).
          # Only the [nil] shape needs the discriminating DOM count,
          # so the good path pays nothing.
          if docs == [nil]
            doc = Document.parse(yaml, schema: schema)
            docs = [] if doc.nil? || doc.document_count.zero?
            doc&.free
          end
          docs
        rescue ParseError
          raise if errors != :collect

          _collect_stream(yaml, schema)
        end
      docs.each { |d| block.call(d) } if block
      docs
    end

    # A column-0 --- / ... marker line. A real document boundary in
    # every valid YAML stream (block/scalar content can never carry one
    # unindented), so the scan is exact — it never splits inside a
    # document. Marker-less boundaries (implicit documents after a
    # ...) stay INSIDE their slice, and each slice parses through the
    # full stream face, so nothing is lost there either. Slices keep
    # their marker lines so every slice parses standalone. Used only by
    # the errors: :collect fallback — a stream that parses whole never
    # splits (the fallback's lossy cases are the whole reason #881
    # exists; the good path must stay exact).
    STREAM_MARKER = /\A(?:---|\.\.\.)(?:[ \t]|\r?\n|\z)/

    # The marker-delimited slices of a stream. A slice that began at a
    # marker line always survives (a trailing bare `---` is an empty
    # document — nil, like psych yields); only a comments/blank-only
    # leading prefix (no document) drops.
    def _stream_slices(yaml)
      slices = []
      current = +""
      markered = false
      yaml.each_line do |line|
        if line.match?(STREAM_MARKER)
          slices << current if markered || !current.strip.empty?
          current = line.dup
          markered = true
        else
          current << line
        end
      end
      slices << current if markered || !current.strip.empty?
      slices
    end

    # The errors: :collect fallback: parse marker-boundary slices
    # through the full stream face; a failed slice's position carries
    # the ParseError. Documents before the bad one still load — the
    # per-document rescue-and-skip contract, centralized.
    def _collect_stream(yaml, schema)
      results = []
      _stream_slices(yaml).each do |slice|
        begin
          results.concat(_drain_all(slice, schema))
        rescue ParseError => e
          results << e
        end
      end
      results
    end

    # The engine capability behind each_document (the CBOR.available?
    # pattern): false when the loaded libyeptris predates the stream
    # iterator — the walk itself raises the stale-engine message at use.
    def each_document?
      FFI::STREAM_ITER
    end

    # The tolerant per-document walk (engine #921): every document of
    # the stream reaches the block IN STREAM ORDER — a valid document
    # yields (document, nil); a failed document yields (nil, error)
    # and the walk CONTINUES at the next line-start marker, so the
    # valid documents after a bad one are kept (load_stream with
    # errors: :raise would drop the whole stream; :collect recovers by
    # a regex slice split, which quoted scalars spanning marker-looking
    # lines can defeat — the engine iterator frames scanner-accurately,
    # so those documents fail as ONE unit instead of splitting).
    # Errors carry the failed document's own line/column and its
    # stream index. Without a block, an Enumerator over the pairs.
    def each_document(yaml, schema: :compat_11, max_depth: 0, &block)
      return enum_for(:each_document, yaml, schema: schema, max_depth: max_depth) unless block

      yaml = Yeptris.read_input(yaml)
      yaml = yaml.to_s
      opts = FFI::ParseOptions.new
      opts[:schema] = schema == :compat_11 ? FFI::SCHEMA_11_COMPAT : FFI::SCHEMA_12_CORE
      opts[:max_depth] = max_depth
      it = FFI.yeptris_stream_iter_new(yaml, yaml.bytesize, opts)
      doc_p = ::FFI::MemoryPointer.new(:pointer)
      idx_p = ::FFI::MemoryPointer.new(:size_t)
      line_p = ::FFI::MemoryPointer.new(:uint32)
      col_p = ::FFI::MemoryPointer.new(:uint32)
      begin
        loop do
          st = FFI.yeptris_stream_iter_next(it, doc_p, idx_p)
          doc_ptr = doc_p.read_pointer
          break if st == FFI::OK && doc_ptr.null? # the stream is over

          index = FFI.read_c_size_t(idx_p)
          if st == FFI::OK
            doc = Document.without_finalizer(doc_ptr, yaml)
            begin
              yield doc.to_ruby, nil
            ensure
              doc.free
            end
          else
            FFI.yeptris_stream_iter_status(it, line_p, col_p)
            reason = st == FFI::ERROR_DEPTH ? "depth limit exceeded" : "parse error"
            yield nil,
                  ParseError.new(
                    "stream document #{index}: #{reason} at line #{line_p.read_uint32}, " \
                    "column #{col_p.read_uint32}"
                  )
            break if st == FFI::ERROR_MEMORY || st == FFI::ERROR_ENCODING
          end
        end
      ensure
        FFI.yeptris_stream_iter_free(it)
      end
    end

    # The Marshal fast path when the loaded libyeptris has it (>= 0.1.11
    # era builds), falling back to the columnar drain and finally the
    # record drain — one code path, the fastest the library offers.
    # The marshal lane is refused for sources that may name a quoted
    # symbol: the C builder keeps the quotes in the name (#1304), and
    # the columns/record walks carry the strip law.
    def _drain_all(yaml, schema)
      if FFI::MARSHAL && ValueML.marshal_lane_ok?(yaml)
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
    # width: the emitter's best_width. 0/nil rides the engine default
    # (80, folding — flow collections after a value past the width, and
    # with the #1257 flip also block plain/single-quoted scalars, the
    # psych/libyaml stored-file behavior); a negative width is psych's
    # line_width: -1 unwrap (the engine clamps it to never-fold).
      def dump(obj, canonical: false, header: false, width: nil)
      BulkBuilder.dump(obj, canonical: canonical, header: header, width: width)
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

      def dump(obj, canonical: false, header: false, width: nil)
        # The nil root rides the bare form (psych's dump(nil) == "\n",
        # #290): the engine's r201 quoted-form law ("a document-root
        # empty scalar rides the quoted form" -- the plain form does not
        # re-parse, the roundtrip invariant) renders the built empty
        # scalar as "" -- correct for the engine's generic serializer,
        # wrong for the psych surface. The binding maps an empty stream
        # back to nil on load (load\#docs.empty?\#nil), so the bare form
        # round-trips THROUGH THE BINDING while keeping the engine's
        # invariant untouched.
        return header ? "--- \n" : "\n" if obj.nil? && !canonical
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
        doc.serialize(canonical: canonical, best_width: width || 0,
                      explicit_doc_start: header)
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
              elsif k.is_a?(String) && k == "<<"
                # stdlib yaml_tree: a literal chevron key carries the
                # explicit !!str tag (single-quoted) so it does not
                # re-load as a merge
                scalar("<<", STYLE_SQ, emit, blob, off)
                emit.call(BUILD_TAG, 0, off[0], 5)
                blob << "!!str"
                off[0] += 5
              elsif k.is_a?(String)
                # keys ride psych's ONE visit_String law — stdlib applies
                # it to keys and values alike, so the reshape words quote
                # in BOTH positions ("n": 1, 'yes': ...; #1264's premise
                # had the psych side inverted: stdlib quotes these keys
                # on every version since 4.0.2). The engine's own
                # plain-key-safety re-check still guards the position.
                style = STYLE_BY_NAME[string_style(k)]
                scalar(k, style, emit, blob, off)
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
        return false if s.match?(/[\n\t\u0085\u2028\u2029\uFEFF]/)
        c = s[0]
        return false if "#,[]{}&*!|>'\"%@`".include?(c)
        return false if "-?:".include?(c) && (s.length == 1 || s[1] =~ /[ \t]/)
        return false if s.include?(": ") || s.end_with?(":") || s.include?(" #")
        return false if RESHAPES_SET[s]
        # ints/sexagesimals reshape: the compat resolver accepts any
        # digit start (compat11.c), psych's ScalarScanner likewise —
        # "07:00:00" plain re-reads as Integer, so leading-zero hours
        # quote too (psych dumps them quoted)
        return false if s.match?(/\A[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+\z/)
        return false if s.match?(/\A[-+]?(0|[1-9][0-9_]*)\z/)
        # compat's float grammar REQUIRES the dot ("1e3" re-reads as a
        # String and may dump plain); psych's FLOAT has no trailing
        # [.:] group — "1.2.3" is a String and dumps plain (pinned by
        # spec/yaml_spec.rb)
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
        # \n and \r are BREAKS in libyaml, not specials - the emitter's
        # single-quoted law carries them ('x y z\n\n  ': single_quoted_
        # allowed survives line breaks, #1264's family A); other C0
        # bytes and DEL need the escapes
        return :double if s.match?(/[\u0085\u2028\u2029\uFEFF]/)
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
            elsif k.is_a?(::String) && k == "<<"
              # stdlib yaml_tree: a literal chevron key carries the
              # explicit !!str tag so it does not re-load as a merge
              key_node = doc.new_scalar("<<", :single_quoted)
              key_node.set_tag("tag:yaml.org,2002:str")
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
