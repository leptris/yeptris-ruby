# frozen_string_literal: true

require "yeptris"

module Yeptris
  # The plan face (engine plan.h; yeptris-ruby#411, the rs
  # `pub mod plan` parity surface): compile a strict-JSON plan spec
  # once, apply it to a document (the DOM leg) or a JSON tape (the
  # tape leg), and read typed COLUMNS — no Ruby tree ever
  # materializes on the hot path.
  #
  #     plan = Yeptris::Plan.compile('{"kind":"seq","children":[
  #              {"name":"id","kind":"int"},{"name":"name","kind":"str"}]}')
  #     result = doc.plan_walk(plan)
  #     result.ints(0)   # => [1, 2]
  #     result.strs(1)   # => ["a", "b"]
  #
  # {Yeptris::JSON::Descriptor} stays the lutaml-vocabulary layer
  # (build-time Ruby hashes, eager row hashes); this module is the
  # cross-runtime face the "query" benchmark op rides — spec strings
  # in, typed columns out, indexed by COLUMN NUMBER (rs parity).
  module Plan
    # Column kinds (plan.h's YEP_PLAN_*).
    COLUMN_KINDS = { 0 => :int, 1 => :float, 2 => :str, 3 => :bool }.freeze
    private_constant :COLUMN_KINDS

    # Raised for a malformed spec (compile) and for a document/tape
    # whose shape disagrees with the plan (walk).
    class Error < ::Yeptris::Error; end

    # A compiled plan. The engine handle rides an AutoPointer (freed
    # at GC); #free releases it eagerly.
    class Plan
      # @api private — minted by .compile
      def initialize(c_ptr)
        @c_ptr = ::FFI::AutoPointer.new(
          c_ptr, self.class.method(:release_handle)
        )
        @freed = false
      end

      def self.release_handle(ptr)
        ::Yeptris::FFI.yeptris_plan_free(ptr)
      end
      private_class_method :release_handle

      def column_count
        ::Yeptris::FFI.yeptris_plan_column_count(@c_ptr)
      end

      def free
        return if @freed

        @freed = true
        @c_ptr.free
        nil
      end

      def freed?
        @freed
      end

      # @api private — the raw handle for the walk calls
      attr_reader :c_ptr
    end

    # The typed columnar result of one walk. Accessors read the C
    # result lazily and CACHE the materialized Ruby arrays; the result
    # borrows the walked source for string columns (the source and —
    # DOM leg — the document are retained here, so the borrow cannot
    # dangle while the result lives). #free releases the C handle;
    # use after free raises, and a result left to GC still frees (the
    # Document finalizer pattern).
    class PlanColumns
      # Shared between the instance and its GC finalizer (Procs close
      # over variables by reference — the Document pattern).
      Freed = Struct.new(:flag)

      # @api private — minted by the walk faces
      def initialize(c_ptr, src: nil, doc: nil)
        @c_ptr = c_ptr
        @src = src
        @doc = doc
        @freed = Freed.new(false)
        @cache = {}
        ObjectSpace.define_finalizer(self, self.class.finalize(c_ptr, @freed))
      end

      def self.finalize(ptr, freed)
        proc do
          next if freed.flag

          freed.flag = true
          ::Yeptris::FFI.yeptris_plan_result_free(ptr)
        end
      end

      def rows
        ensure_alive!
        ::Yeptris::FFI.yeptris_plan_result_rows(@c_ptr)
      end
      alias count rows

      # The column's kind: :int, :float, :str, or :bool.
      def column_kind(col)
        ensure_alive!
        COLUMN_KINDS.fetch(::Yeptris::FFI.yeptris_plan_result_kind(@c_ptr, col), col)
      end

      # INT columns as Integer; BOOL columns read through the same
      # lane as 0/1 (the engine's columnar contract, rs parity).
      def ints(col)
        read_typed(col, :int)
      end

      # BOOL columns mapped to true/false.
      def bools(col)
        read_typed(col, :bool)
      end

      def floats(col)
        read_typed(col, :float)
      end

      # STR columns: decoded UTF-8 strings (spans materialize at
      # first read — nothing borrowed crosses).
      def strs(col)
        read_typed(col, :str)
      end

      # The column's null markers: true where the row's leaf was null
      # or missing. One boolean per row.
      def nulls(col)
        read_nulls(col).map { |v| v == 1 }
      end

      def free
        return if @freed.flag

        @freed.flag = true
        ObjectSpace.undefine_finalizer(self)
        ::Yeptris::FFI.yeptris_plan_result_free(@c_ptr)
        nil
      end

      def freed?
        @freed.flag
      end

      private

      def ensure_alive!
        return unless @freed.flag

        raise Error, "the plan result was freed"
      end

      def rows!
        @rows ||= rows
      end

      def read_nulls(col)
        @cache["nulls:#{col}"] ||= begin
          n = rows!
          n.zero? ? [] :
            ::Yeptris::FFI.yeptris_plan_result_nulls(@c_ptr, col)
              .read_bytes(n).unpack("C*")
        end
      end

      def read_typed(col, want)
        ensure_alive!
        kind = COLUMN_KINDS.fetch(::Yeptris::FFI.yeptris_plan_result_kind(@c_ptr, col), col)
        raise Error, "column #{col} is #{kind.inspect}, not #{want.inspect}" unless
          kind == want || (want == :bool && kind == :bool) ||
          (want == :int && kind == :bool)

        # the shared int lane serves INT (raw) and BOOL columns; the
        # want decides the mapping (ints reads bools as 0/1 — the rs
        # parity contract — bools maps to true/false)
        @cache["#{want}:#{col}"] ||= if kind == :str
                                       read_str_column(col)
                                     elsif kind == :float
                                       read_float_lane(col)
                                     elsif want == :bool
                                       read_bool_lane(col)
                                     else
                                       read_int_lane(col)
                                     end
      end

      def read_int_lane(col)
        n = rows!
        nulls = read_nulls(col)
        return [] if n.zero?

        vals = ::Yeptris::FFI.yeptris_plan_result_ints(@c_ptr, col)
                .read_bytes(n * 8).unpack("q<*")
        return vals unless nulls.include?(1)

        Array.new(n) { |i| nulls[i] == 1 ? nil : vals[i] }
      end

      # BOOL rides the int lane (0/1); maps to true/false with the
      # null slots preserved.
      def read_bool_lane(col)
        n = rows!
        nulls = read_nulls(col)
        return [] if n.zero?

        vals = ::Yeptris::FFI.yeptris_plan_result_ints(@c_ptr, col)
                .read_bytes(n * 8).unpack("q<*")
        Array.new(n) { |i| nulls[i] == 1 ? nil : vals[i] == 1 }
      end

      def read_float_lane(col)
        n = rows!
        nulls = read_nulls(col)
        return [] if n.zero?

        vals = ::Yeptris::FFI.yeptris_plan_result_floats(@c_ptr, col)
                .read_bytes(n * 8).unpack("E*")
        return vals unless nulls.include?(1)

        Array.new(n) { |i| nulls[i] == 1 ? nil : vals[i] }
      end

      # The tape leg: spans into the retained source; the DOM leg:
      # (ptr,len) views into the document. Both materialize to Ruby
      # strings.
      def read_str_column(col)
        n = rows!
        nulls = read_nulls(col)
        if @doc
          base = ::FFI::Pointer.new(::Yeptris::FFI.yeptris_plan_result_strs(@c_ptr, col))
          stride = ::Yeptris::FFI::PlanStr.size
          Array.new(n) do |i|
            next nil if nulls[i] == 1

            v = ::Yeptris::FFI::PlanStr.new(base + i * stride)
            v[:p].read_bytes(v[:len]).force_encoding(Encoding::UTF_8)
          end
        else
          decode = ::Yeptris::JSON.method(:decode_span)
          offs = ::Yeptris::FFI.yeptris_plan_result_str_offs(@c_ptr, col)
                  .read_bytes(n * 4).unpack("V*")
          lens = ::Yeptris::FFI.yeptris_plan_result_str_lens(@c_ptr, col)
                  .read_bytes(n * 4).unpack("V*")
          Array.new(n) { |i| nulls[i] == 1 ? nil : decode.call(@src, offs[i], lens[i]) }
        end
      end
    end

    module_function

    # Compiles a plan from a strict-JSON spec STRING (plan.h's
    # contract — kind/path/children; rs parity: the spec crosses as
    # text, no Ruby-hash layer). Raises {Plan::Error} on a malformed
    # spec.
    def compile(spec)
      spec = spec.to_s
      st = ::FFI::MemoryPointer.new(:int)
      raw = ::Yeptris::FFI.yeptris_plan_compile(spec, spec.bytesize, st)
      raise Error,
            "plan compile failed (status=#{st.read_int}): #{Yeptris::FFI.last_error_message}" if raw.null?

      Plan.new(raw)
    end

    # @api private — the tape leg's reader (Yeptris::JSON::Tape#plan_walk)
    def walk_tape(tape, plan)
      st = ::FFI::MemoryPointer.new(:int)
      raw = ::Yeptris::FFI.yeptris_tape_plan_walk(tape.c_ptr, plan.c_ptr, st)
      if raw.null?
        raise Error,
              "plan walk failed (status=#{st.read_int}) — the document shape " \
              "disagrees with the plan"
      end

      PlanColumns.new(raw, src: tape.source)
    end

    # @api private — the DOM leg's reader (Yeptris::Document#plan_walk)
    def walk_document(doc, plan)
      st = ::FFI::MemoryPointer.new(:int)
      raw = ::Yeptris::FFI.yeptris_document_plan_walk(doc.c_ptr, plan.c_ptr, st)
      if raw.null?
        raise Error,
              "plan walk failed (status=#{st.read_int}) — the document shape " \
              "disagrees with the plan"
      end

      PlanColumns.new(raw, doc: doc)
    end
  end
end
