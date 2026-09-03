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
             :best_width, :int
    end

    attach_function :yeptris_version, [], :string

    attach_function :yeptris_last_error, [:pointer, :pointer], :string

    attach_function :yeptris_parse, %i[pointer size_t yeptris_status_out], :yeptris_document
    attach_function :yeptris_parse_ex,
                    %i[pointer size_t pointer yeptris_status_out], :yeptris_document
    attach_function :yeptris_parse_json, %i[pointer size_t yeptris_status_out], :yeptris_document

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

    attach_function :yeptris_serialize, %i[yeptris_document pointer], :pointer
    attach_function :yeptris_serialize_ex,
                    %i[yeptris_document pointer pointer], :pointer
    attach_function :yeptris_serialize_json, %i[yeptris_document pointer], :pointer

    # Owned char* results (serialize*): one reader, freed exactly once.
    # The buffers are plain malloc'd C memory (the header contract says
    # "caller frees"), so the release is libc free.
    attach_function :c_free, :free, [:pointer], :void

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
        ::Yeptris::FFI.c_free(ptr)
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

    SCHEMA_12_CORE = 0
    SCHEMA_11_COMPAT = 1

    OK = 0
    ERROR_PARSE = 1
    ERROR_MEMORY = 2
    ERROR_DEPTH = 3
    ERROR_ENCODING = 4
    ERROR_ARG = 6
  end
end
