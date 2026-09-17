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

    autoload :Descriptor, "yeptris/json/descriptor"

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
    T_TRUE = 2
    T_FALSE = 3
    T_INT = 4
    T_FLOAT = 5
    T_STR = 6
    T_SEQ_OPEN = 7
    T_MAP_OPEN = 8
    T_CLOSE = 9

    # The tape keeps RAW string spans (escapes untouched — the C
    # contract); the walk decodes them here. The hot path (no
    # backslash) returns the slice untouched.
    SIMPLE_ESCAPES = {
      '"' => '"'.b, "\\" => "\\".b, "/" => "/".b, "b" => "\b".b, "f" => "\f".b,
      "n" => "\n".b, "r" => "\r".b, "t" => "\t".b
    }.freeze

    def decode_span(src, off, len)
      s = src.byteslice(off, len)
      s.force_encoding(Encoding::UTF_8)
      return s unless s.include?("\\")

      b = s.b
      out = +"".b
      i = 0
      n = b.bytesize
      while i < n
        c = b.getbyte(i)
        if c != 0x5C || i + 1 >= n
          out << c
          i += 1
          next
        end
        e = b.getbyte(i + 1)
        if e != 0x75 # simple escape
          ch = e.chr
          out << (SIMPLE_ESCAPES[ch] || ch)
          i += 2
          next
        end
        cp = b.byteslice(i + 2, 4).to_i(16)
        if cp >= 0xD800 && cp <= 0xDBFF && i + 12 <= n &&
           b.getbyte(i + 6) == 0x5C && b.getbyte(i + 7) == 0x75
          lo = b.byteslice(i + 8, 4).to_i(16)
          if lo >= 0xDC00 && lo <= 0xDFFF
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            i += 12
          else
            i += 6
          end
        else
          i += 6
        end
        out << [cp].pack("U").b
      end
      out.force_encoding(Encoding::UTF_8)
    end

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
      # v2: parse records number spans only — ONE bulk convert call
      # materializes them (per-number FFI calls would sink the ladder)
      ivp = ::FFI::MemoryPointer.new(:int64, n, true)
      dvp = ::FFI::MemoryPointer.new(:double, n, true)
      ::Yeptris::FFI.yeptris_tape_convert(tape, 0, n, ivp, dvp)
      vals_i = ivp.read_bytes(n * 8).unpack("q<*")
      vals_f = dvp.read_bytes(n * 8).unpack("E*")
      # any integer text beyond int64: every INT rebuilds from its span
      # (exact Bignum; JSON.parse parity) — int_min is set by the
      # convert call above
      exact_ints = !tape[:int_min].zero?
      utf8 = src.encoding == Encoding::UTF_8

      docs = [nil] # record 0 (DOC) pre-consumed — the root's slot
      stack = []
      key_sets = STRICT_DUPLICATE_KEYS ? [{}] : nil
      pending_key = nil
      i = 1
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
          text = lens[i] == 0 ? +"".force_encoding(Encoding::UTF_8) : decode_span(src, offs[i], lens[i])
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
        when T_TRUE, T_FALSE # v2: the kind IS the value
          place(docs, stack, pending_key) { kinds[i] == T_TRUE }
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

    def dump(obj)
      parts = String.new(encoding: Encoding::BINARY,
                         capacity: 12 * 16) # 12-byte entries, appended in place
      blob = String.new(encoding: Encoding::BINARY)
      off = [0]
      place_obj(obj, parts, blob, off)
      doc = ::Yeptris::Document.create
      # FFI passes String args BY REFERENCE — no MemoryPointer copies
      rc = doc.build_entries(parts, parts.bytesize / 12, blob, blob.bytesize)
      raise DumpError, "document_build failed: #{rc}" unless rc == ::Yeptris::FFI::OK
      out = ::Yeptris::FFI::JSON_EX ? doc.serialize_json_compact : doc.serialize_json
      # JSON.generate emits no trailing newline (the document writer does)
      out.end_with?("\n") ? out[0, out.bytesize - 1] : out
    ensure
      doc&.free
    end

    F = ::Yeptris::FFI
    MAP_E = [F::BUILD_MAP, 0, 0, 0].pack("CCx2VV").freeze
    SEQ_E = [F::BUILD_SEQ, 0, 0, 0].pack("CCx2VV").freeze
    END_E = [F::BUILD_END, 0, 0, 0].pack("CCx2VV").freeze
    DQ = F::STYLE_DOUBLE_QUOTED
    PL = F::STYLE_PLAIN
    SC_DQ = [F::BUILD_SCALAR, DQ].pack("CCx2").freeze
    SC_PL = [F::BUILD_SCALAR, PL].pack("CCx2").freeze

    def place_obj(obj, parts, blob, off)
      case obj
      when Hash
        parts << MAP_E
        obj.each do |k, v|
          key = k.is_a?(String) ? k : k.is_a?(Symbol) ? k.name : k.to_s
          scalar_json(key, SC_DQ, parts, blob, off)
          place_obj(v, parts, blob, off)
        end
        parts << END_E
      when Array
        parts << SEQ_E
        obj.each { |e| place_obj(e, parts, blob, off) }
        parts << END_E
      when String
        scalar_json(obj, SC_DQ, parts, blob, off)
      when Symbol
        scalar_json(obj.name, SC_DQ, parts, blob, off)
      when Integer, Float
        scalar_json(obj.to_s, SC_PL, parts, blob, off)
      when true
        scalar_json("true", SC_PL, parts, blob, off)
      when false
        scalar_json("false", SC_PL, parts, blob, off)
      when nil
        scalar_json("null", SC_PL, parts, blob, off)
      when Date, Time
        scalar_json(obj.iso8601, SC_DQ, parts, blob, off)
      else
        raise DumpError, "cannot dump #{obj.class}: unsupported object " \
                         "(JSON.generate calls to_json on custom types)"
      end
    end

    def scalar_json(text, prefix, parts, blob, off)
      parts << (prefix + [off[0], text.bytesize].pack("VV"))
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
