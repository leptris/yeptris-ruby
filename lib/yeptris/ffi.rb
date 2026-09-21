# frozen_string_literal: true

require "ffi"

module Yeptris
  # Every public C declaration, attached exactly once (the leptris-ruby
  # seam discipline: status checking and owned-pointer reading live in
  # check_status / read_owned_string, never hand-rolled at call sites).
  module FFI
    extend ::FFI::Library

    begin
      ffi_lib [
        ENV["YEPTRIS_LIB_PATH"],
        File.expand_path("../../libyeptris.dylib", __dir__),
        File.expand_path("../../libyeptris.so", __dir__),
        File.expand_path("../../libyeptris.dll", __dir__),
        "/usr/local/lib/libyeptris.dylib",
        "/usr/local/lib/libyeptris.so",
        "yeptris",
      ].compact
    rescue LoadError => e
      raise LoadError, <<~MSG
        yeptris: cannot load the libyeptris library.
        Set YEPTRIS_LIB_PATH to a libyeptris.{so,dylib,dll}, or vendor
        the library next to the gem's lib/ directory.
        (Underlying error: #{e.message})
      MSG
    end

    class << self
      # #138's class, hit again by the oiml-cs report: a stale
      # libyeptris on the machine (the Windows base-name dedupe makes
      # a system copy win) lacks newer symbols, and a raising attach
      # aborts this file mid-evaluation — every constant after it
      # never defines, so the next autoload dies with
      # 'uninitialized constant Yeptris::FFI::NODE_SCALAR'. Attaches
      # now record the miss and define a raising stub of the same
      # name: the load completes, optional surfaces fail with a clear
      # message at USE, and the ESSENTIAL self-check at the bottom of
      # this file raises the friendly load error for truly old
      # engines.
      def attach_function(name, args, ret, opts = {})
        super
      rescue ::FFI::NotFoundError, ::FFI::TypeError
        define_singleton_method(name) do |*_a, **_kw|
          raise ::FFI::NotFoundError,
                "yeptris: #{name} is unavailable — the loaded " \
                "libyeptris is older than this gem. Update the engine " \
                "library (or clear the stale copy shadowing it)."
        end
        (@missing ||= []) << name
        nil
      end
    end


    typedef :pointer, :yeptris_document
    typedef :pointer, :yeptris_node
    typedef :pointer, :yeptris_status_out
    typedef :int, :yeptris_status

    # YeptrisParseOptions (parse.h): schema, max_depth, strict,
    # tab_policy, recover. ABI-frozen field order.
    class ParseOptions < ::FFI::Struct
      layout :schema, :int,
             :max_depth, :int,
             :strict, :int,
             :tab_policy, :int,
             :recover, :int
    end

    # yeptris_emit_options (emit.h): versioned by size.
    class EmitOptions < ::FFI::Struct
      layout :size, :uint32,
             :canonical, :int,
             :best_width, :int,
             :explicit_doc_start, :int
    end

    attach_function :yeptris_version, [], :string

    attach_function :yeptris_last_error, [:pointer, :pointer], :string

    attach_function :yeptris_parse, %i[pointer size_t yeptris_status_out], :yeptris_document
    attach_function :yeptris_parse_ex,
                    %i[pointer size_t pointer yeptris_status_out], :yeptris_document
    attach_function :yeptris_parse_json, %i[pointer size_t yeptris_status_out], :yeptris_document

    # The JSON tape (TODO.restructure/85; the JSON surface's load
    # engine — issue #81): ONE call, three bulk columns, spans borrow
    # the caller's string (no arena copy, no second validating parse).
    # v2 records: numbers are spans at parse; yeptris_tape_convert
    # materializes them in one bulk call.
    # v3 (libyeptris 0.6.9): the interleaved records (recs) are the
    # primary storage on the lenient route; the strict route keeps the
    # columns eager. The layout MUST mirror yeptris_json_tape — a stale
    # layout makes C write past the FFI buffer (a silent heap overflow
    # that only some allocators catch; the 0.6.9.1 windows crash).
    class JsonTape < ::FFI::Struct
      layout :count, :size_t, :kinds, :pointer, :offs, :pointer,
             :lens, :pointer, :recs, :pointer, :_cols_ready, :int,
             :_rec_primary, :int, :int_min, :int64, :_src, :pointer,
             :_srclen, :size_t, :_block, :pointer
    end

    attach_function :yeptris_parse_json_tape, %i[pointer size_t pointer], :int
    attach_function :yeptris_tape_free, [:pointer], :void
    attach_function :yeptris_tape_convert, %i[pointer size_t size_t pointer pointer], :size_t

    # the compiled plan walk (#293 / TODO.restructure/87): compile a
    # strict-JSON spec once, apply it to a parsed tape in one C pass,
    # read the typed COLUMNAR result
    attach_function :yeptris_plan_compile, %i[pointer size_t pointer], :pointer
    attach_function :yeptris_plan_free, [:pointer], :void
    attach_function :yeptris_plan_column_count, [:pointer], :size_t
    attach_function :yeptris_tape_plan_walk, %i[pointer pointer pointer], :pointer
    attach_function :yeptris_plan_result_free, [:pointer], :void
    attach_function :yeptris_plan_result_rows, [:pointer], :size_t
    attach_function :yeptris_plan_result_kind, %i[pointer size_t], :int
    attach_function :yeptris_plan_result_ints, %i[pointer size_t], :pointer
    attach_function :yeptris_plan_result_floats, %i[pointer size_t], :pointer
    attach_function :yeptris_plan_result_str_offs, %i[pointer size_t], :pointer
    attach_function :yeptris_plan_result_str_lens, %i[pointer size_t], :pointer
    attach_function :yeptris_plan_result_nulls, %i[pointer size_t], :pointer

    # the DOM (YAML) leg of the plan walk (#293 slice three): same
    # compiled plan over a parsed document; str columns expose
    # (ptr,len) views into the document's regions
    attach_function :yeptris_document_plan_walk, %i[yeptris_document pointer pointer], :pointer
    attach_function :yeptris_plan_result_strs, %i[pointer size_t], :pointer

    # yeptris_plan_str (plan.h): one string view
    class PlanStr < ::FFI::Struct
      layout :p, :pointer, :len, :size_t
    end

    attach_function :yeptris_document_free, [:yeptris_document], :void
    attach_function :yeptris_document_count, [:yeptris_document], :size_t
    attach_function :yeptris_document_root, [:yeptris_document, :size_t], :yeptris_node

    # construction (TODO.impl/11 phase 3)
    attach_function :yeptris_document_new, [], :yeptris_document
    attach_function :yeptris_document_set_root,
                    %i[yeptris_document yeptris_node], :int
    attach_function :yeptris_node_new_mapping, [:yeptris_document], :yeptris_node
    attach_function :yeptris_node_new_sequence, [:yeptris_document], :yeptris_node
    attach_function :yeptris_node_new_scalar,
                    %i[yeptris_document pointer size_t int], :yeptris_node
    attach_function :yeptris_node_map_add,
                    %i[yeptris_node pointer size_t yeptris_node], :int
    attach_function :yeptris_node_map_add_node,
                    %i[yeptris_node yeptris_node yeptris_node], :int
    attach_function :yeptris_node_map_set,
                    %i[yeptris_node pointer size_t yeptris_node], :int
    attach_function :yeptris_node_map_del, %i[yeptris_node pointer size_t], :int
    attach_function :yeptris_node_seq_add, %i[yeptris_node yeptris_node], :int
    attach_function :yeptris_node_seq_del, %i[yeptris_node size_t], :int
    attach_function :yeptris_node_set_anchor, %i[yeptris_node pointer size_t], :int
    attach_function :yeptris_node_set_tag, %i[yeptris_node pointer size_t], :int
    attach_function :yeptris_node_new_alias,
                    %i[yeptris_document yeptris_node pointer size_t], :yeptris_node

    attach_function :yeptris_node_kind, [:yeptris_node], :int
    attach_function :yeptris_node_id, [:yeptris_node], :uint32
    attach_function :yeptris_node_value, %i[yeptris_node pointer], :pointer
    attach_function :yeptris_node_style, [:yeptris_node], :int
    attach_function :yeptris_node_tag, %i[yeptris_node pointer], :pointer
    attach_function :yeptris_node_anchor, %i[yeptris_node pointer], :pointer
    attach_function :yeptris_node_alias_target, [:yeptris_node], :yeptris_node
    attach_function :yeptris_node_tag_id, [:yeptris_node], :int
    attach_function :yeptris_node_int, %i[yeptris_node pointer], :yeptris_status
    attach_function :yeptris_node_float, %i[yeptris_node pointer], :yeptris_status
    attach_function :yeptris_node_bool, %i[yeptris_node pointer], :yeptris_status
    attach_function :yeptris_node_seq_count, [:yeptris_node], :size_t
    attach_function :yeptris_node_seq_at, %i[yeptris_node size_t], :yeptris_node
    attach_function :yeptris_node_children,
                    %i[yeptris_node pointer size_t], :size_t
    attach_function :yeptris_node_map_count, [:yeptris_node], :size_t
    attach_function :yeptris_node_map_get, %i[yeptris_node pointer size_t], :yeptris_node
    attach_function :yeptris_node_map_at,
                    %i[yeptris_node size_t pointer pointer], :int

    attach_function :yeptris_tag_uri, [:int], :string

    # recorder (TODO.impl/12): bulk records + string arena, one drain
    attach_function :yeptris_recorder_new, [], :pointer
    attach_function :yeptris_recorder_new_ex, [:int], :pointer
    attach_function :yeptris_recorder_feed,
                    %i[pointer pointer size_t int], :int
    attach_function :yeptris_recorder_records, %i[pointer pointer], :pointer
    attach_function :yeptris_recorder_arena, %i[pointer pointer], :pointer
    attach_function :yeptris_recorder_free, [:pointer], :void

    # value stream (TODO.impl/15 phase F): one drain of pre-converted
    # typed values — the materialization fast path
    attach_function :yeptris_value_drain,
                    %i[pointer size_t int pointer pointer pointer pointer], :int
    attach_function :yeptris_value_free, %i[pointer pointer], :void

    # Columnar drain (libyeptris > 0.1.1): the same stream as parallel
    # typed buffers, one carved allocation. Feature-detected — the
    # record API is the fallback on older libraries.
    COLUMNS = begin
      attach_function :yeptris_value_drain_columns, %i[pointer size_t int pointer], :int
      attach_function :yeptris_value_free_columns, [:pointer], :void
      true
    rescue ::FFI::NotFoundError
      false
    end

    class ValueColumns < ::FFI::Struct
      layout :count, :size_t, :arena_len, :size_t,
             :payloads, :pointer, :offs, :pointer, :lens, :pointer,
             :kinds, :pointer, :tags, :pointer, :is_keys, :pointer,
             :bools, :pointer, :arena, :pointer
    end

    # Marshal 4.8 emission (TODO.restructure/21): the C side converts
    # value records directly into Ruby's wire format; the binding
    # materializes the whole graph with one core-C Marshal.load call
    # instead of walking per-value records in pure Ruby. Same feature-
    # detect discipline as the columnar drain (older libraries fall
    # back to the record walk).
    MARSHAL_ALL_DOCS = 0
    MARSHAL_FIRST_DOC = 1
    attach_function :yeptris_marshal,
                    %i[pointer size_t int int pointer pointer], :int
    attach_function :yeptris_marshal_node,
                    %i[yeptris_node pointer pointer], :int
    attach_function :yeptris_marshal_free, [:pointer], :void
    # The bulk child drain (#168's quadratic): O(n) iteration for
    # #each/#each_pair. Engines without it fall back to the per-index
    # walk (correct, quadratic).
    CHILDREN_DRAIN = !(@missing ||= []).include?(:yeptris_node_children)
    MARSHAL = !(@missing ||= []).include?(:yeptris_marshal_node)

    # bulk build (TODO.impl/15 phase D): one call raises a document
    BUILD_SCALAR = 1
    BUILD_SEQ = 2
    BUILD_MAP = 3
    BUILD_END = 4
    BUILD_TAG = 5

    # the ABI-pinned shape; the bulk builder packs these bytes
    # directly (12 per entry)
    class BuildEntry < ::FFI::Struct
      layout op: :uint8, style: :uint8, reserved: :uint16, off: :uint32, len: :uint32
    end
    attach_function :yeptris_document_build,
                    %i[yeptris_document pointer size_t pointer size_t], :int

    attach_function :yeptris_serialize, %i[yeptris_document pointer], :pointer
    attach_function :yeptris_serialize_ex,
                    %i[yeptris_document pointer pointer], :pointer
    attach_function :yeptris_serialize_json, %i[yeptris_document pointer], :pointer

    # compact JSON generation (JSON.generate's shape); absent on
    # libraries before v0.2.5 — the JSON surface feature-detects
    JSON_EX = begin
      attach_function :yeptris_serialize_json_ex, %i[yeptris_document pointer int], :pointer
      true
    rescue ::FFI::NotFoundError
      false
    end

    # CBOR (RFC 8949, TODO.cbor): absent on libraries before the
    # codec's release — the CBOR module feature-detects
    attach_function :yeptris_cbor_decode, %i[pointer size_t uint32 yeptris_status_out],
                    :yeptris_document
    callback :cbor_item_cb, %i[pointer yeptris_document size_t], :int
    attach_function :yeptris_cbor_decode_sequence,
                    %i[pointer size_t uint32 cbor_item_cb pointer yeptris_status_out], :size_t
    attach_function :yeptris_cbor_encode, %i[yeptris_document uint32 pointer], :pointer
    attach_function :yeptris_cbor_encode_sequence,
                    %i[pointer size_t uint32 pointer], :pointer
    CBOR_EX = !(@missing ||= []).include?(:yeptris_cbor_decode)

    # Owned char* results (serialize*): one reader, freed exactly once.
    # The release goes through yeptris_free (libyeptris's own
    # allocator-matching free) because ffi's :free attach has no
    # Windows process-symbol fallback — libyeptris.dll doesn't export
    # libc free, so resolving :free against it fails on Windows.
    # A raised attach ABORTS this file mid-evaluation — everything
    # after it (NODE_SCALAR and the kind constants below) never
    # defines, and a lazily autoloaded node.rb then dies with
    # 'uninitialized constant' (#138). Every fallback attaches too.
    YEPTRIS_FREE = begin
      attach_function :yeptris_free, [:pointer], :void
      :direct
    rescue ::FFI::NotFoundError
      begin
        # libyeptris < v0.6.6: POSIX resolves :free through the
        # process symbol table, so the libc attach still works there.
        attach_function :yeptris_free, :free, [:pointer], :void
        :libc
      rescue ::FFI::NotFoundError
        # no owned-buffer release on this lib+platform combination;
        # Owned.string leaks instead of killing the whole file
        :none
      end
    end

    module Owned
      module_function

      # Reads a NUL-terminated malloc'd C string into an Encoding
      # UTF_8 String, then frees the buffer. len_out (nullable) is a
      # MemoryPointer carrying the byte length from the producing call.
      def string(ptr, len_out = nil)
        return nil if ptr.null?

        len = len_out&.read_uint64
        s = if len && len > 0
              ptr.read_bytes(len).force_encoding(Encoding::UTF_8)
            else
              ptr.read_string.force_encoding(Encoding::UTF_8)
            end
        ::Yeptris::FFI.yeptris_free(ptr) if ::Yeptris::FFI::YEPTRIS_FREE != :none
        s
      end
    end

    module_function

    # Non-OK status -> ParseError carrying the C error channel's
    # message with line/column. NULL-document failures route through
    # here too (parse detail lives on the same channel).
    def check_status(status, action)
      return if status.zero?

      raise Yeptris::ParseError, "#{action} failed: #{last_error_message}"
    end

    def last_error_message
      line = ::FFI::MemoryPointer.new(:uint32)
      col = ::FFI::MemoryPointer.new(:uint32)
      msg = yeptris_last_error(line, col)
      detail = msg.to_s
      l = line.read_uint32
      c = col.read_uint32
      l.positive? ? "#{detail} at line #{l}, column #{c}" : detail
    end

    # Pinned enum values (test_abi): the constants the binding relies
    # on without a C header at runtime.
    NODE_SCALAR = 0
    NODE_SEQUENCE = 1
    NODE_MAPPING = 2
    NODE_ALIAS = 3

    STYLE_PLAIN = 1
    STYLE_SINGLE_QUOTED = 2
    STYLE_DOUBLE_QUOTED = 3
    STYLE_LITERAL = 4
    STYLE_FOLDED = 5

    TAG_STR = 0
    TAG_INT = 1
    TAG_FLOAT = 2
    TAG_BOOL = 3
    TAG_NULL = 4
    TAG_TIMESTAMP = 5
    TAG_BINARY = 8

    # the schema-descriptor API (issue #238; TODO.restructure/83)
    DESC_ABI = 1
    SCHEMA_ERROR = 9

    class DescNode < ::FFI::Struct
        layout :wire_name, :pointer, :kind, :uint8, :type_tag, :uint8,
               :flags, :uint16, :child_index, :uint32, :child_count, :uint32,
               :reserved, :uint32
      end

    class SchemaColumn < ::FFI::Struct
        layout :data, :pointer, :capacity, :uint32, :count, :uint32
    end

    attach_function :yeptris_schema_load,
                    %i[pointer size_t int pointer uint32 uint32 pointer], :int

    SCHEMA_12_CORE = 0
    SCHEMA_11_COMPAT = 1

    OK = 0
    ERROR_PARSE = 1
    ERROR_MEMORY = 2
    ERROR_DEPTH = 3
    ERROR_ENCODING = 4
    ERROR_IO = 5
    ERROR_ARG = 6
    ERROR_UNSUPPORTED = 7
    ERROR_INTERNAL = 8
    # The load-time essentials (the read path + the ownership
    # contract): absent on engines far older than the optional
    # surfaces — raise the friendly error once every constant has
    # fully defined, so no partial-module state leaks into autoloads
    # (the #138 class, closed at the root).
    ESSENTIAL = %i[
      yeptris_version yeptris_last_error yeptris_parse yeptris_parse_ex
      yeptris_parse_json yeptris_document_free yeptris_document_count
      yeptris_document_root yeptris_node_kind yeptris_node_value
      yeptris_node_tag_id yeptris_node_style yeptris_document_new
      yeptris_document_set_root yeptris_serialize yeptris_serialize_ex
    ].freeze
    missing_core = ESSENTIAL & (@missing ||= [])
    raise ::FFI::NotFoundError,
          "yeptris: the loaded libyeptris is older than this gem " \
          "requires (missing: #{missing_core.join(', ')}). Update the " \
          "engine library, or clear the stale copy shadowing it." \
          unless missing_core.empty?

  end
end
