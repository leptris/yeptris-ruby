# frozen_string_literal: true

module Yeptris
  # Value-stream materialization (TODO.impl/15 phase F): one drain of
  # PRE-CONVERTED typed values from the C side, then a minimal Ruby
  # walk — no per-scalar parsing (the number kernels already ran),
  # key/value pairing rides the entries' is_key bit, anchors arrive
  # as uniform entries decorating the value they bind. The Psych
  # quirks re-decide from tag_id + the raw bytes every entry carries.
  module ValueML
    DOC = 0
    V_NULL = 1
    V_BOOL = 2
    V_INT = 3
    V_FLOAT = 4
    V_STR = 5
    V_TS = 6
    SEQ_OPEN = 7
    MAP_OPEN = 8
    CLOSE = 9
    ALIAS = 10
    ANCHOR = 11

    FIELDS = 7
    VALUE_SIZE = 24
    # kind, tag, is_key, b | off, len | pad4 | payload (INT/FLOAT bits)
    UNPACK = "C4V2x4q<"

    module_function

    def load_all(yaml, schema: :compat_11)
      yaml = yaml.read if yaml.respond_to?(:read)
      yaml = yaml.to_s
      vals_p = ::FFI::MemoryPointer.new(:pointer)
      count_p = ::FFI::MemoryPointer.new(:uint64)
      arena_p = ::FFI::MemoryPointer.new(:pointer)
      alen_p = ::FFI::MemoryPointer.new(:uint64)
      st = FFI.yeptris_value_drain(
        yaml, yaml.bytesize,
        schema == :compat_11 ? FFI::SCHEMA_11_COMPAT : FFI::SCHEMA_12_CORE,
        vals_p, count_p, arena_p, alen_p
      )
      raise ParseError, FFI.last_error_message if st != FFI::OK

      vals = vals_p.read_pointer
      arena = arena_p.read_pointer
      begin
        count = count_p.read_uint64
        flat = vals.read_bytes(count * VALUE_SIZE).unpack(UNPACK * count)
        arena_bytes = arena.read_bytes(alen_p.read_uint64)
        arena_bytes.force_encoding(Encoding::UTF_8)
        walk(flat, arena_bytes)
      ensure
        FFI.yeptris_value_free(vals, arena)
      end
    end

    def load(yaml, schema: :compat_11)
      docs = load_all(yaml, schema: schema)
      docs.empty? ? nil : docs.first
    end

    # field offsets in the unpacked 7-tuple
    KIND = 0
    TAG = 1
    IS_KEY = 2
    B = 3
    OFF = 4
    LEN = 5
    P64 = 6

    def walk(flat, arena)
      docs = []
      stack = []
      anchors = {}
      pending_key = []
      pending_key_tag = []
      pending_anchor = nil
      merge_target = []

      i = 0
      n = flat.length
      while i < n
        kind = flat[i + KIND]
        case kind
        when V_STR
          text = arena.byteslice(flat[i + OFF], flat[i + LEN])
          # implicit-plain ':name' scans to a Symbol (Psych's
          # ScalarScanner); quoted ':x' stays a String
          v = if flat[i + B] == 1 && text.length > 1 &&
                text.start_with?(":") && !text.start_with?("::")
                text[1..].to_sym
              else
                text
              end
          if pending_anchor
            anchors[pending_anchor] = v
            pending_anchor = nil
          end
          slot(docs, stack, pending_key, pending_key_tag, v, merge_target, flat, i)
        when V_INT
          v = flat[i + P64]
          if pending_anchor
            anchors[pending_anchor] = v
            pending_anchor = nil
          end
          slot(docs, stack, pending_key, pending_key_tag, v, merge_target, flat, i)
        when V_FLOAT
          text = arena.byteslice(flat[i + OFF], flat[i + LEN])
          # Psych's float grammar requires the dot (or an inf/nan
          # word, or sexagesimal ':') — exponent-only forms are
          # Strings even when the compat tag says FLOAT
          v = if text.include?(".") || text.include?(":") || text.start_with?(".")
                [flat[i + P64]].pack("q<").unpack1("E")
              else
                text
              end
          if pending_anchor
            anchors[pending_anchor] = v
            pending_anchor = nil
          end
          slot(docs, stack, pending_key, pending_key_tag, v, merge_target, flat, i)
        when V_BOOL
          text = arena.byteslice(flat[i + OFF], flat[i + LEN])
          # Psych quirk: single-char y/n stay Strings
          v = text.length == 1 ? text : flat[i + B] == 1
          if pending_anchor
            anchors[pending_anchor] = v
            pending_anchor = nil
          end
          slot(docs, stack, pending_key, pending_key_tag, v, merge_target, flat, i)
        when V_NULL
          slot(docs, stack, pending_key, pending_key_tag, nil, merge_target, flat, i)
        when V_TS
          v = Materializer.parse_timestamp(arena.byteslice(flat[i + OFF], flat[i + LEN]))
          if pending_anchor
            anchors[pending_anchor] = v
            pending_anchor = nil
          end
          slot(docs, stack, pending_key, pending_key_tag, v, merge_target, flat, i)
        when MAP_OPEN
          h = {}
          if pending_anchor
            anchors[pending_anchor] = h
            pending_anchor = nil
          end
          merge_target.push(slot(docs, stack, pending_key, pending_key_tag, h, merge_target,
                                 flat, i))
          stack.push(h)
          pending_key.push(nil)
          pending_key_tag.push(nil)
        when SEQ_OPEN
          a = []
          if pending_anchor
            anchors[pending_anchor] = a
            pending_anchor = nil
          end
          merge_target.push(slot(docs, stack, pending_key, pending_key_tag, a, merge_target,
                                 flat, i))
          stack.push(a)
          pending_key.push(nil)
          pending_key_tag.push(nil)
        when CLOSE
          closed = stack.pop
          pending_key.pop
          pending_key_tag.pop
          target = merge_target.pop
          Materializer.merge_into(target, closed) if target
        when DOC
          docs.push(nil)
        when ALIAS
          v = anchors[arena.byteslice(flat[i + OFF], flat[i + LEN])]
          slot(docs, stack, pending_key, pending_key_tag, v, merge_target, flat, i)
        when ANCHOR
          pending_anchor = arena.byteslice(flat[i + OFF], flat[i + LEN])
        end
        i += FIELDS
      end
      docs
    end

    # Places a completed value: document root, sequence entry, or a
    # map's key (is_key) / value (completing the pending pair).
    # Returns the merge TARGET when the value is a still-empty
    # container placed under a '<<' key — the open-site caller pushes
    # it so the matching CLOSE merges into it (an inline map's
    # contents arrive after its open); scalar merges apply now.
    def slot(docs, stack, pending_key, pending_key_tag, v, _merge_target, flat, i)
      if stack.empty?
        docs[-1] = v
        return nil
      end
      parent = stack.last
      if parent.is_a?(Array)
        parent.push(v)
        return nil
      end
      if flat[i + IS_KEY] == 1
        pending_key[-1] = v
        pending_key_tag[-1] = flat[i + TAG]
        return nil
      end
      key = pending_key[-1]
      pending_key[-1] = nil
      if key == "<<" && pending_key_tag[-1] == 9 # TAG_MERGE
        if (v.is_a?(Hash) || v.is_a?(Array)) && v.empty?
          parent # deferred: contents arrive after the open
        else
          Materializer.merge_into(parent, v)
          nil
        end
      else
        parent[key] = v
        nil
      end
    end
  end
end
