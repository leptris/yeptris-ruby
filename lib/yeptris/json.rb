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

    module_function

    def load(source)
      source = ::Yeptris.read_input(source)
      source = source.to_s
      if defined?(::Yeptris::Native)
        begin
          return ::Yeptris::Native.load_json(source)
        rescue ::Yeptris::ParseError => e
          raise ParseError, e.message
        end
      end
      strict_fallback(source)
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
          walk_strict(cols)
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
    def walk_strict(cols)
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
          place(docs, stack, pending_key) { {} }
          pending_key = nil
        when ValueML::CLOSE
          stack.pop
        when ValueML::V_STR
          text = arena.byteslice(offs[i], lens[i])
          if ikeys[i] == 1 && !stack.empty? && stack.last.is_a?(Hash)
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
