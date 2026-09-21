# frozen_string_literal: true

module Yeptris
  # The schema-descriptor materialization (issue #238; the C ABI lives
  # in yeptris/schema.h and docs/schema-abi.md). One native pass fills
  # typed columns against a caller-compiled descriptor; the
  # intermediate generic document never exists.
  module Schema
    module_function

    KIND = { scalar: 0, sequence: 1, mapping: 2, callback: 3 }.freeze
    TYPE = { str: 0, int: 1, float: 2, bool: 3, null: 4, any: 5 }.freeze
    REQUIRED = 1 << 0
    FIRST_WINS = 1 << 1 # duplicates within one mapping: first kept

    # The :any verdict (#238's headroom): the resolver's own typing,
    # one 24-byte record per value — Integer/Float/true/false/nil, a
    # zero-copy String for str/timestamp spans
    ANY_SIZE = 24 # yeptris_value.h's YeptrisValue: kind@0 tag_id@1
    # is_key@2 b@3 off@4 len@8 p@16 — the C layout, ABI-pinned
    ANY_KIND = { 1 => :null, 2 => :bool, 3 => :int, 4 => :float,
                 5 => :str, 6 => :timestamp }.freeze

    class Error < Yeptris::Error; end

    # #238's executed headroom (ST_ANY/FIRST_WINS) rides the C tag
    # AFTER v0.6.12; probe the engine rather than trusting versions
    class << self
      def headroom_supported?
        return @headroom_supported unless @headroom_supported.nil?
        @headroom_supported = begin
          load("x: 1\n",
               desc: [{ kind: :mapping, child_index: 1, child_count: 1 },
                      { wire_name: "x", kind: :scalar, type: :any }]) && true
        rescue Error, Yeptris::ParseError, Yeptris::Error
          false
        end
      end
    end
    class RequiredMissing < Error; end

    ELEMENT_SIZE = { 0 => 16, 1 => 8, 2 => 8, 3 => 1, 4 => 1, 5 => ANY_SIZE }.freeze # by TYPE value

    # A materialized span: zero-copy off/len into the source plus the
    # node's byte offset (the CALLBACK escape hatch).
    Span = Struct.new(:offset, :length, :node_offset) do
      def bytes_from(source)
        source.byteslice(offset, length)
      end
    end

    # desc: a flat array of node hashes, the C ABI 1:1 —
    #   { wire_name:, kind:, type:, required:, child_index:, child_count: }
    # (kind/type symbolic; wire_name nil = the root). Returns one typed
    # Ruby array per node: Integer/Float/true/false/nil/String for
    # scalars and sequence elements (document order), Span for
    # callbacks.
    def load(source, schema: :core_12, desc:, capacity: 64)
      source = Yeptris.read_input(source).to_s
      schema_id = schema == :compat_11 ? FFI::SCHEMA_11_COMPAT : FFI::SCHEMA_12_CORE
      plans = compile(desc)
      loop do
        result = run(source, schema_id, plans, capacity)
        return result unless result == :grow
        capacity *= 2
      end
    end

    # #184 (lutaml-model KV path): zip Schema columns into record
    # hashes ready for Serializable.instantiate. Mapping root → one
    # hash; sequence-of-mappings → one hash per element; nested
    # mappings → nested hashes. Returns Array<Hash> always. when_attribute
    # / polymorphic stay out of scope (interpretive fallback).
    def load_records(source, schema: :core_12, desc:, capacity: 64)
      cols = load(source, schema: schema, desc: desc, capacity: capacity)
      zip_records(desc, cols)
    end

    def zip_records(desc, cols)
      root = desc[0] || {}
      case root[:kind]
      when :sequence
        child_start = root[:child_index] || 1
        child_count = root[:child_count] || 0
        return [] if child_count.zero?

        child = desc[child_start]
        if child && child[:kind] == :mapping
          field_start = child[:child_index] || (child_start + 1)
          field_count = child[:child_count] || 0
          fields = desc[field_start, field_count] || []
          field_cols = cols[field_start, field_count] || []
          nrows = field_cols.map(&:length).max || 0
          Array.new(nrows) do |r|
            h = {}
            fields.each_with_index do |f, i|
              next unless f[:wire_name]
              col = field_cols[i] || []
              h[f[:wire_name].to_sym] = materialize_field(f, desc, cols, col[r])
            end
            h
          end
        else
          (cols[child_start] || []).map { |v| { value: v } }
        end
      when :mapping
        field_start = root[:child_index] || 1
        field_count = root[:child_count] || 0
        fields = desc[field_start, field_count] || []
        field_cols = cols[field_start, field_count] || []
        h = {}
        fields.each_with_index do |f, i|
          next unless f[:wire_name]
          col = field_cols[i] || []
          h[f[:wire_name].to_sym] = materialize_field(f, desc, cols, col[0])
        end
        [h]
      else
        [{ value: cols[0]&.first }]
      end
    end
    private_class_method :zip_records

    def materialize_field(field, desc, cols, cell)
      case field[:kind]
      when :mapping
        start = field[:child_index] || 0
        count = field[:child_count] || 0
        return nil if count.zero? || cell.nil?

        nested = {}
        desc[start, count]&.each_with_index do |nf, i|
          next unless nf[:wire_name]
          ncol = cols[start + i] || []
          nested[nf[:wire_name].to_sym] = ncol.is_a?(Array) ? (ncol[0] rescue cell) : cell
        end
        nested
      when :sequence
        cell.is_a?(Array) ? cell : Array(cell)
      else
        cell
      end
    end
    private_class_method :materialize_field

    def compile(desc)
      desc.map do |n|
        { kind: KIND.fetch(n.fetch(:kind)),
          type: TYPE.fetch(n[:type] || :str),
          wire: n[:wire_name],
          flags: (n[:required] ? REQUIRED : 0) | (n[:first_wins] ? FIRST_WINS : 0),
          child_index: n[:child_index] || 0,
          child_count: n[:child_count] || 0 }
      end
    end
    private_class_method :compile

    def run(source, schema_id, plans, capacity) # rubocop:disable Metrics/MethodLength
      n = plans.length
      desc_buf = ::FFI::MemoryPointer.new(FFI::DescNode, n, true)
      wires = []
      plans.each_with_index do |p, i|
        node = FFI::DescNode.new(desc_buf + i * FFI::DescNode.size)
        if p[:wire]
          wires << (wire = ::FFI::MemoryPointer.from_string(p[:wire]))
          node[:wire_name] = wire
        end
        node[:kind] = p[:kind]
        node[:type_tag] = p[:type]
        node[:flags] = p[:flags]
        node[:child_index] = p[:child_index]
        node[:child_count] = p[:child_count]
        node[:reserved] = 0
      end
      cols_buf = ::FFI::MemoryPointer.new(FFI::SchemaColumn, n, true)
      data_ptrs = []
      plans.each_with_index do |p, i|
        col = FFI::SchemaColumn.new(cols_buf + i * FFI::SchemaColumn.size)
        elem = ELEMENT_SIZE.fetch(p[:type], 16)
        data = ::FFI::MemoryPointer.new(elem, capacity, true)
        data_ptrs << data
        col[:data] = data
        col[:capacity] = capacity
        col[:count] = 0
      end

      src = ::FFI::MemoryPointer.from_string(source) # NUL-safe copy for the C side
      st = FFI.yeptris_schema_load(src, source.bytesize, schema_id, desc_buf, n,
                                   FFI::DESC_ABI, cols_buf)
      case st
      when FFI::OK
        plans.each_with_index.map { |p, i| drain(cols_buf, i, p, source) }
      when FFI::ERROR_MEMORY
        :grow
      when FFI::SCHEMA_ERROR
        msg = FFI.last_error_message
        raise RequiredMissing, msg
      else
        raise Yeptris::ParseError, FFI.last_error_message
      end
    end
    private_class_method :run

    def drain(cols_buf, i, plan, source)
      col = FFI::SchemaColumn.new(cols_buf + i * FFI::SchemaColumn.size)
      count = col[:count]
      data = col[:data]
      case plan[:kind]
      when KIND[:callback]
        Array.new(count) do |k|
          off = data.get_uint32(k * 16)
          len = data.get_uint32(k * 16 + 4)
          node_off = data.get_uint32(k * 16 + 8)
          Span.new(off, len, node_off)
        end
      else
        type = plan[:type]
        Array.new(count) do |k|
          case type
          when TYPE[:int] then data.get_int64(k * 8)
          when TYPE[:float] then data.get_double(k * 8)
          when TYPE[:bool] then data.get_uchar(k) == 1
          when TYPE[:null] then nil
          when TYPE[:any]
            rec = k * ANY_SIZE
            case ANY_KIND[data.get_uint8(rec)]
            when :int then data.get_int64(rec + 16)
            when :float then data.get_double(rec + 16)
            when :bool then data.get_uint8(rec + 3) == 1
            when :null then nil
            else # str/timestamp: the zero-copy span
              source.byteslice(data.get_uint32(rec + 4), data.get_uint32(rec + 8))
            end
          else
            off = data.get_uint32(k * 16)
            len = data.get_uint32(k * 16 + 4)
            source.byteslice(off, len)
          end
        end
      end
    end
    private_class_method :drain
  end
end
