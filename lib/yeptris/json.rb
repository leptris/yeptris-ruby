# frozen_string_literal: true

module Yeptris
  # The STRICT JSON surface (TODO.restructure/31).
  #
  # `Yeptris::JSON.load` targets EXACT `JSON.parse` semantics — that
  # is its parity target, spec-pinned (spec/json_parity_spec.rb).
  # It is deliberately separate from Yeptris::YAML: the YAML surface
  # keeps the Psych contract for every input (JSON-shaped included),
  # so the two never drift into each other's semantics.
  #
  # Engines, fastest first (both exact — the parity spec runs against
  # whichever is loaded):
  # 1. the native materializer (fused C scan → VALUE; opt-in build)
  # 2. the record drain + strict conversion walk (always available)
  module JSON
    class Error < ::Yeptris::Error; end
    class ParseError < Error; end

    # json gem 3.0 made duplicate keys an error by DEFAULT; 2.x is
    # last-wins. The parity target is the RESOLVED json gem's own
    # behavior — strictness follows it (issue #37, found by canon's
    # CI where json 3.0.0 resolved while the dev box had 2.x).
    require "json"
    STRICT_DUPLICATE_KEYS = Gem::Version.new(::JSON::VERSION) >= Gem::Version.new("3")

    module_function

    def load(source)
      source = ::Yeptris.read_input(source)
      source = source.to_s
      if defined?(::Yeptris::Native)
        begin
          return ::Yeptris::Native.load_json(source, STRICT_DUPLICATE_KEYS)
        rescue ::Yeptris::ParseError => e
          raise ParseError, e.message
        end
      end
      tape_engine(source)
    end

    # The tape engine (issue #81): ONE call validates and materializes
    # the record stream; the walk reads four bulk columns and slices
    # strings straight out of the caller's source — no gate document,
    # no recorder transform, no arena copy (the drain path paid all
    # three, which is where medium/large throughput went).
    T_DOC = 0
    T_NULL = 1
    T_BOOL = 2
    T_INT = 3
    T_FLOAT = 4
    T_STR = 5
    T_SEQ_OPEN = 6
    T_MAP_OPEN = 7
    T_CLOSE = 8

    def tape_engine(source)
      tape = ::Yeptris::FFI::JsonTape.new
      rc = ::Yeptris::FFI.yeptris_parse_json_tape(source, source.bytesize, tape)
      raise ParseError, ::Yeptris::FFI.last_error_message if rc != ::Yeptris::FFI::OK

      begin
        walk_tape(source, tape)
      ensure
        ::Yeptris::FFI.yeptris_tape_free(tape)
      end
    end

    def walk_tape(src, tape)
      n = tape[:count]
      kinds = tape[:kinds].read_bytes(n).unpack("C*")
      offs = tape[:offs].read_bytes(n * 4).unpack("V*")
      lens = tape[:lens].read_bytes(n * 4).unpack("V*")
      raw = tape[:vals].read_bytes(n * 8)
      vals_i = raw.unpack("q<*")
      vals_f = raw.unpack("E")
      # any integer text beyond int64: every INT rebuilds from its span
      # (exact Bignum; JSON.parse parity)
      exact_ints = !tape[:int_min].zero?
      utf8 = src.encoding == Encoding::UTF_8

      docs = []
      stack = []
      key_sets = STRICT_DUPLICATE_KEYS ? [{}] : nil
      pending_key = nil
      i = 1 # record 0 is the DOC boundary
      while i < n
        case kinds[i]
        when T_SEQ_OPEN
          place(docs, stack, pending_key) { [] }
          pending_key = nil
        when T_MAP_OPEN
          key_sets&.push({})
          place(docs, stack, pending_key) { {} }
          pending_key = nil
        when T_CLOSE
          stack.pop
          key_sets&.pop
        when T_STR
          text = src.byteslice(offs[i], lens[i])
          text.force_encoding(Encoding::UTF_8) unless utf8
          if pending_key.nil? && !stack.empty? && stack.last.is_a?(Hash)
            if key_sets && key_sets.last.key?(text)
              raise ParseError, %(duplicate key "#{text}" in JSON object)
            end
            key_sets&.last&.store(text, true)
            pending_key = text
          else
            place(docs, stack, pending_key) { text }
            pending_key = nil
          end
        when T_INT
          if exact_ints
            place(docs, stack, pending_key) { Integer(src.byteslice(offs[i], lens[i]), 10) }
          else
            v = vals_i[i]
            place(docs, stack, pending_key) { v }
          end
          pending_key = nil
        when T_FLOAT
          v = vals_f[i]
          place(docs, stack, pending_key) { v }
          pending_key = nil
        when T_BOOL
          v = vals_i[i] == 1
          place(docs, stack, pending_key) { v }
          pending_key = nil
        when T_NULL
          place(docs, stack, pending_key) { nil }
          pending_key = nil
        else
          raise Error, "internal: impossible tape record #{kinds[i]}"
        end
        i += 1
      end
      docs.empty? ? nil : docs.first
    end

    # The always-available engine: the strict-JSON validator gates
    # (parse_json raises on anything RFC 8259 rejects), then the
    # value records convert WITHOUT the Psych quirk table — floats
    # are always Floats, bools always bools ("1e3" is 1000.0 here
    # and a String on the YAML surface; each surface is its own
    # contract).
    def strict_fallback(source)
      begin
        gate = ::Yeptris::Document.parse_json(source)
      rescue ::Yeptris::ParseError => e
        raise ParseError, e.message
      end
      begin
        cols = ::Yeptris::FFI::ValueColumns.new
        st = ::Yeptris::FFI.yeptris_value_drain_columns(
          source, source.bytesize, ::Yeptris::FFI::SCHEMA_12_CORE, cols
        )
        raise ParseError, ::Yeptris::FFI.last_error_message if st != ::Yeptris::FFI::OK

        begin
          walk_strict(cols, STRICT_DUPLICATE_KEYS)
        ensure
          ::Yeptris::FFI.yeptris_value_free_columns(cols)
        end
      ensure
        gate.free
      end
    end

    # Placement mechanics mirror ValueML.walk_columns; the CONVERSION
    # is the strict-JSON one (no ':sym' scan, no y/n quirk, no
    # dot-required floats). Anchors/aliases/timestamps cannot occur
    # in strict JSON — reaching them is an internal error.
    def walk_strict(cols, strict_dup = STRICT_DUPLICATE_KEYS)
      n = cols[:count]
      kinds = cols[:kinds].read_bytes(n).unpack("C*")
      ikeys = cols[:is_keys].read_bytes(n).unpack("C*")
      bools = cols[:bools].read_bytes(n).unpack("C*")
      offs = cols[:offs].read_bytes(n * 4).unpack("V*")
      lens = cols[:lens].read_bytes(n * 4).unpack("V*")
      pays = cols[:payloads].read_bytes(n * 8).unpack("q<*")
      arena = cols[:arena_len].zero? ? +"" : cols[:arena].read_bytes(cols[:arena_len])
      arena.force_encoding(Encoding::UTF_8)

      docs = []
      stack = []
      key_sets = strict_dup ? [{}] : nil
      pending_key = nil
      i = 0
      while i < n
        case kinds[i]
        when ValueML::DOC
          docs.push(nil)
        when ValueML::SEQ_OPEN
          place(docs, stack, pending_key) { [] }
          pending_key = nil
        when ValueML::MAP_OPEN
          key_sets&.push({})
          place(docs, stack, pending_key) { {} }
          pending_key = nil
        when ValueML::CLOSE
          stack.pop
          key_sets&.pop
        when ValueML::V_STR
          text = arena.byteslice(offs[i], lens[i])
          if ikeys[i] == 1 && !stack.empty? && stack.last.is_a?(Hash)
            if strict_dup && key_sets.last.key?(text)
              raise ParseError, %(duplicate key "#{text}" in JSON object)
            end
            key_sets&.last&.store(text, true)
            pending_key = text
          else
            # Records carry int64 payloads: an integer-beyond-int64
            # degrades to a PLAIN string (b==1). In strict JSON a
            # plain (unquoted) scalar can ONLY be a number — every
            # real string is quoted and arrives b==0 — so rebuild the
            # exact Integer (JSON.parse parity, Bignum included).
            if bools[i] == 1
              place(docs, stack, pending_key) { Integer(text, 10) }
            else
              place(docs, stack, pending_key) { text }
            end
            pending_key = nil
          end
        when ValueML::V_INT
          place(docs, stack, pending_key) { pays[i] }
          pending_key = nil
        when ValueML::V_FLOAT
          place(docs, stack, pending_key) { [pays[i]].pack("q<").unpack1("E") }
          pending_key = nil
        when ValueML::V_BOOL
          place(docs, stack, pending_key) { bools[i] == 1 }
          pending_key = nil
        when ValueML::V_NULL
          place(docs, stack, pending_key) { nil }
          pending_key = nil
        else
          raise Error, "internal: impossible record #{kinds[i]} in strict JSON"
        end
        i += 1
      end
      docs.empty? ? nil : docs.first
    end

    # ---- generation (issue #81) ------------------------------------------
    #
    # `dump` targets JSON.generate semantics for the core types: the
    # object walk reuses YAML.dump's packed-entry bulk builder (one
    # FFI build call), then the strict-JSON writer serializes —
    # Strings ride DOUBLE_QUOTED (a "42" stays quoted; numbers, bools
    # and null stay plain), Symbols become their name.
    class DumpError < Error; end

    ENTRY_BYTES = 12
    MAP_ENTRY = [::Yeptris::FFI::BUILD_MAP, 0, 0, 0].pack("CCx2VV").freeze
    SEQ_ENTRY = [::Yeptris::FFI::BUILD_SEQ, 0, 0, 0].pack("CCx2VV").freeze
    END_ENTRY = [::Yeptris::FFI::BUILD_END, 0, 0, 0].pack("CCx2VV").freeze
    CONT_ENTRY = { ::Yeptris::FFI::BUILD_MAP => MAP_ENTRY, ::Yeptris::FFI::BUILD_SEQ => SEQ_ENTRY,
                   ::Yeptris::FFI::BUILD_END => END_ENTRY }.freeze

    def dump(obj)
      parts = []
      blob = String.new(encoding: Encoding::BINARY)
      off = [0]
      emit = lambda do |op, style, o, len|
        parts << (o.zero? && len.zero? && style.zero? ? CONT_ENTRY[op] :
                    [op, style, o, len].pack("CCx2VV"))
      end
      place_obj(obj, emit, blob, off)
      doc = ::Yeptris::Document.create
      buf = ::FFI::MemoryPointer.from_string(parts.join)
      bblob = ::FFI::MemoryPointer.from_string(blob)
      rc = doc.build_entries(buf, parts.length, bblob, blob.bytesize)
      raise DumpError, "document_build failed: #{rc}" unless rc == ::Yeptris::FFI::OK
      out = ::Yeptris::FFI::JSON_EX ? doc.serialize_json_compact : doc.serialize_json
      # JSON.generate emits no trailing newline (the document writer does)
      out.end_with?("\n") ? out[0, out.bytesize - 1] : out
    ensure
      doc&.free
    end

    def place_obj(obj, emit, blob, off)
      case obj
      when Hash
        emit.call(::Yeptris::FFI::BUILD_MAP, 0, 0, 0)
        obj.each do |k, v|
          key = k.is_a?(String) ? k : k.is_a?(Symbol) ? k.name : k.to_s
          scalar_json(key, ::Yeptris::FFI::STYLE_DOUBLE_QUOTED, emit, blob, off)
          place_obj(v, emit, blob, off)
        end
        emit.call(::Yeptris::FFI::BUILD_END, 0, 0, 0)
      when Array
        emit.call(::Yeptris::FFI::BUILD_SEQ, 0, 0, 0)
        obj.each { |e| place_obj(e, emit, blob, off) }
        emit.call(::Yeptris::FFI::BUILD_END, 0, 0, 0)
      when String
        scalar_json(obj, ::Yeptris::FFI::STYLE_DOUBLE_QUOTED, emit, blob, off)
      when Symbol
        scalar_json(obj.name, ::Yeptris::FFI::STYLE_DOUBLE_QUOTED, emit, blob, off)
      when Integer, Float, true, false, nil
        text = obj.nil? ? "null" : obj.to_s
        scalar_json(text, ::Yeptris::FFI::STYLE_PLAIN, emit, blob, off)
      when Date, Time
        scalar_json(obj.iso8601, ::Yeptris::FFI::STYLE_DOUBLE_QUOTED, emit, blob, off)
      else
        raise DumpError, "cannot dump #{obj.class}: unsupported object " \
                         "(JSON.generate calls to_json on custom types)"
      end
    end

    def scalar_json(text, style, emit, blob, off)
      emit.call(::Yeptris::FFI::BUILD_SCALAR, style, off[0], text.bytesize)
      blob << text
      off[0] += text.bytesize
    end

    def place(docs, stack, key)
      v = yield
      if stack.empty?
        docs[-1] = v
      elsif key
        stack.last[key] = v
      else
        stack.last.push(v)
      end
      stack.push(v) if v.is_a?(Array) || v.is_a?(Hash)
      v
    end
  end
end
