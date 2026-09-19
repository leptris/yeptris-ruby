# frozen_string_literal: true

module Yeptris
  # CBOR (RFC 8949) over the same FFI document the rest of the
  # binding rides (TODO.cbor/04). Decode materializes through the
  # Psych-compatible path; encode builds the tree with YAMLTree and
  # hands the document to the C encoder — plain data only (aliases
  # and non-decimal tag text are unencodable by the C contract).
  #
  # Representation notes inherited from the decoder: integers beyond
  # int64 and bignums materialize as their shortest-double text, byte
  # strings as tag-chained text — CBOR's JSON-data-model mapping.
  module CBOR
    STRICT = (1 << 0) # decode: reject non-minimal arguments
    CANONICAL = (1 << 1) # encode: s4.2.1 core deterministic profile

    class Error < Yeptris::Error; end
    class UnencodableError < Error; end

    module_function

    def available?
      defined?(::Yeptris::FFI::CBOR_EX) && ::Yeptris::FFI::CBOR_EX
    end

    def load(data, strict: false)
      raise Error, "libyeptris has no CBOR support" unless available?

      doc_ptr = ::Yeptris::FFI.yeptris_cbor_decode(data, data.bytesize, strict ? STRICT : 0, nil)
      raise ParseError, ::Yeptris::FFI.last_error_message if doc_ptr.null?

      # the wrapper's finalizer also frees — its idempotent #free is
      # the ONLY release path (a raw double free corrupts the heap)
      doc = ::Yeptris::Document.new(doc_ptr)
      doc.root.to_ruby
    ensure
      doc&.free
    end

    def load_sequence(data, strict: false)
      raise Error, "libyeptris has no CBOR support" unless available?

      items = []
      pending_error = nil
      receiver = ::FFI::Function.new(:int, %i[pointer pointer size_t]) do |_ctx, item, _index|
        # the callback owns the item; materialize then free in place
        # (through the wrapper — the finalizer frees too). A raise
        # inside an FFI callback leaves the return value undefined —
        # abort the C iteration cleanly (nonzero) and re-raise after
        begin
          doc = ::Yeptris::Document.new(item)
          items << doc.root&.to_ruby
          doc.free
          0
        rescue ::Exception => e # rubocop:disable Lint/RescueException
          pending_error = e
          1
        end
      end
      st = ::Yeptris::FFI.yeptris_cbor_decode_sequence(
        data, data.bytesize, strict ? STRICT : 0, receiver, nil, nil
      )
      raise pending_error if pending_error
      raise ParseError, ::Yeptris::FFI.last_error_message if st.zero? && !data.empty?

      items
    end

    def dump(obj, canonical: true)
      docs = build_documents([obj])
      begin
        encode_one(docs[0], canonical)
      ensure
        docs.each(&:free)
      end
    end

    def dump_sequence(objects, canonical: true)
      docs = build_documents(objects)
      begin
        opts = canonical ? CANONICAL : 0
        arr = ::FFI::MemoryPointer.new(:pointer, docs.size)
        arr.write_array_of_pointer(docs.map(&:c_ptr))
        len_ptr = ::FFI::MemoryPointer.new(:size_t)
        take_buffer(
          ::Yeptris::FFI.yeptris_cbor_encode_sequence(arr, docs.size, opts, len_ptr),
          len_ptr
        )
      ensure
        docs.each(&:free)
      end
    end

    # -- internals ----------------------------------------------------

    def build_documents(objects)
      # ONE document per object: a visitor's tree is a single
      # document and push sets its root — reuse would overwrite
      objects.map do |obj|
        visitor = ::Yeptris::Psych::Visitors::YAMLTree.new
        visitor.push(obj)
        visitor.document
      end
    end

    def encode_one(doc, canonical)
      opts = canonical ? CANONICAL : 0
      len_ptr = ::FFI::MemoryPointer.new(:size_t)
      take_buffer(::Yeptris::FFI.yeptris_cbor_encode(doc.c_ptr, opts, len_ptr), len_ptr)
    end

    # The encode convenience contract: a malloc'd buffer plus its
    # byte length — binary data, freed through the library's own free.
    def take_buffer(ptr, len_ptr)
      raise UnencodableError, ::Yeptris::FFI.last_error_message if ptr.null?

      len = len_ptr.read_uint64
      ptr.read_bytes(len).force_encoding(Encoding::BINARY)
    ensure
      ::Yeptris::FFI.yeptris_free(ptr) if ptr && !ptr.null?
    end
  end
end
