# frozen_string_literal: true

# The Descriptor plan walk (yeptris#293 slice two, over the C plan
# ABI of libyeptris v0.6.3): compile a row shape once, then apply it
# to a JSON document in ONE native pass producing typed COLUMNS —
# the engine never materializes the intermediate Ruby Hash/Array
# tree (lutaml-model's hydration reads columns, not trees).
#
#     descriptor = Yeptris::JSON::Descriptor.build(
#       kind: :seq, # or :map with path: — the rows container
#       children: [
#         { name: "id", kind: :int },
#         { name: "name", kind: :str },
#       ])
#     result = descriptor.walk(json)
#     result.column("id") # => [1, 2, ...] (nil where null/missing)
#     result.to_a        # => [{ "id" => 1, "name" => "x" }, ...]
#
# Vocabulary alignment with Leptris::XML::Descriptor (the shape
# vocabulary lutaml-model shares across engines): :collection at the
# root is the rows container (the seq form), :scalar is the string
# leaf. Slice one covers rows of scalar leaves — nested plans, the
# YAML leg, and partial descriptors ride the board item
# (TODO.restructure/87).
class Yeptris::JSON::Descriptor
  class Error < ::Yeptris::JSON::Error; end

  # spec leaf kinds → the C column kind codes (plan.h)
  LEAF_KINDS = {
    int: 0,
    float: 1,
    str: 2,
    bool: 3,
    scalar: 2, # leptris's string-value row kind
  }.freeze
  private_constant :LEAF_KINDS

  # root forms: the rows container's shape (:collection is leptris's
  # name for a repeated-rows container)
  ROOT_KINDS = %i[seq map collection].freeze
  private_constant :ROOT_KINDS

  LEAF_SPEC_NAMES = %w[int float str bool].freeze
  private_constant :LEAF_SPEC_NAMES

  class Handle < ::FFI::AutoPointer
    def self.release(ptr)
      ::Yeptris::FFI.yeptris_plan_free(ptr)
    end
  end

  # +kind+: :seq (rows are the root array) or :map (rows live under
  # +path:+'s value). +children+: the leaf columns; each row is a
  # mapping, every child names one typed column.
  def self.build(kind:, path: nil, children:)
    unless ROOT_KINDS.include?(kind)
      raise ArgumentError, "kind must be one of #{ROOT_KINDS.inspect}, got #{kind.inspect}"
    end
    unless children.is_a?(::Array) && !children.empty?
      raise ArgumentError, "children must be a non-empty Array"
    end

    leaves = children.map do |child|
      name = child[:name]
      code = LEAF_KINDS[child[:kind]]
      if code.nil?
        raise ArgumentError,
              "leaf kind must be one of #{LEAF_KINDS.keys.inspect}, got #{child[:kind].inspect}"
      end
      unless name.is_a?(::String) && !name.empty?
        raise ArgumentError, "leaf name must be a non-empty String, got #{name.inspect}"
      end

      { "name" => name, "kind" => LEAF_SPEC_NAMES[code] }
    end

    spec = { "kind" => kind == :map ? "map" : "seq", "children" => leaves }
    spec["path"] = path if path

    # the spec is strict JSON (the C compiler parses it through the
    # strict JSON DOM); compile once, the engine owns the copy
    spec_json = ::JSON.generate(spec)
    st = ::FFI::MemoryPointer.new(:int)
    raw = ::Yeptris::FFI.yeptris_plan_compile(spec_json, spec_json.bytesize, st)
    if raw.null?
      raise Error, "plan compile failed (status=#{st.read_int}): #{spec_json}"
    end

    new(Handle.new(raw), leaves.map { |leaf| leaf["name"] })
  end

  attr_reader :names # the planned leaf names, in spec order

  # @api private — handles come from .build
  def initialize(handle, names)
    @handle = handle
    @names = names.dup.freeze
  end

  # Applies the plan to +json+ (String or IO): parse the tape, one C
  # plan pass, bulk-read the typed columns. The returned PlanResult
  # is standalone Ruby (nothing borrowed from the document).
  def walk(json)
    src = ::Yeptris.read_input(json).to_s
    tape = ::Yeptris::FFI::JsonTape.new
    rc = ::Yeptris::FFI.yeptris_parse_json_tape(src, src.bytesize, tape)
    raise ::Yeptris::JSON::ParseError, ::Yeptris::FFI.last_error_message if rc != ::Yeptris::FFI::OK

    begin
      st = ::FFI::MemoryPointer.new(:int)
      raw = ::Yeptris::FFI.yeptris_tape_plan_walk(tape, @handle, st)
      if raw.null?
        raise Error,
              "plan walk failed (status=#{st.read_int}) — the document shape " \
              "disagrees with the plan"
      end

      begin
        PlanResult.read(raw, src, @names)
      ensure
        ::Yeptris::FFI.yeptris_plan_result_free(raw)
      end
    ensure
      ::Yeptris::FFI.yeptris_tape_free(tape)
    end
  end

  def column_count
    ::Yeptris::FFI.yeptris_plan_column_count(@handle)
  end

  # The eager columnar result of Descriptor#walk: typed Ruby columns
  # keyed by leaf name, plus the row-hash conveniences. Nothing here
  # borrows C memory.
  class PlanResult
    # @api private — one bulk read per column; the C result is freed
    # on return (PlanResult owns plain Ruby data)
    def self.read(raw, src, names)
      rows = ::Yeptris::FFI.yeptris_plan_result_rows(raw)
      columns = {}
      names.each_with_index do |name, c|
        kind = ::Yeptris::FFI.yeptris_plan_result_kind(raw, c)
        columns[name] = read_column(raw, c, kind, rows, src)
      end
      new(rows, names, columns)
    end

    def self.read_column(raw, c, kind, rows, src)
      return [] if rows.zero?

      nulls = ::Yeptris::FFI.yeptris_plan_result_nulls(raw, c).read_bytes(rows).unpack("C*")
      has_nulls = nulls.include?(1)
      case kind
      when 0 # int: the unpacked lane IS the column when no nulls
        ints = ::Yeptris::FFI.yeptris_plan_result_ints(raw, c).read_bytes(rows * 8).unpack("q<*")
        return ints unless has_nulls

        Array.new(rows) { |i| nulls[i] == 1 ? nil : ints[i] }
      when 1
        floats = ::Yeptris::FFI.yeptris_plan_result_floats(raw, c).read_bytes(rows * 8).unpack("E*")
        return floats unless has_nulls

        Array.new(rows) { |i| nulls[i] == 1 ? nil : floats[i] }
      when 3 # bool: 0/1 → false/true (always maps)
        ints = ::Yeptris::FFI.yeptris_plan_result_ints(raw, c).read_bytes(rows * 8).unpack("q<*")
        Array.new(rows) { |i| nulls[i] == 1 ? nil : ints[i] == 1 }
      else # str: spans into the source, escapes decoded on the Ruby side
        offs = ::Yeptris::FFI.yeptris_plan_result_str_offs(raw, c).read_bytes(rows * 4).unpack("V*")
        lens = ::Yeptris::FFI.yeptris_plan_result_str_lens(raw, c).read_bytes(rows * 4).unpack("V*")
        decode = ::Yeptris::JSON.method(:decode_span)
        Array.new(rows) { |i| nulls[i] == 1 ? nil : decode.call(src, offs[i], lens[i]) }
      end
    end
    private_class_method :read_column

    def initialize(rows, names, columns)
      @rows = rows
      @names = names
      @columns = columns
    end

    def rows
      @rows
    end
    alias count rows

    # The planned leaf names, in spec order.
    def names
      @names.dup
    end

    # One typed column: an Array of rows values (nil where the leaf
    # was null, missing, or shape-mismatched).
    def column(name)
      @columns.fetch(name) { raise ArgumentError, "no planned column #{name.inspect}" }
    end

    # Row +i+ as a Hash of the planned leaves (nil out of range).
    def at(i)
      return nil if i >= @rows || i.negative?

      row = {}
      @names.each { |n| row[n] = @columns[n][i] }
      row
    end

    # Rows as Hashes — the tree-shaped convenience; column readers
    # are the allocation-lean path.
    def to_a
      Array.new(@rows) { |i| at(i) }
    end
    alias to_ruby to_a # leptris's eager-tree vocabulary

    def each_row(&block)
      return enum_for(:each_row) unless block

      @rows.times { |i| block.call(at(i)) }
    end
  end
end
