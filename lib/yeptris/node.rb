# frozen_string_literal: true

require "date"
require "time"

# A node inside a document. Borrowed C memory: every call routes
# through the owning document's liveness check — use after free
# raises Yeptris::FreedError, never a segfault.
class Yeptris::Node
  include Enumerable

  attr_reader :c_ptr

  # @api private — always constructed via Document#wrap_node (identity).
  def initialize(c_ptr, document)
    @c_ptr = c_ptr
    @document = document
  end

  def document
    @document
  end

  KINDS = {
    Yeptris::FFI::NODE_SCALAR => :scalar,
    Yeptris::FFI::NODE_SEQUENCE => :sequence,
    Yeptris::FFI::NODE_MAPPING => :mapping,
    Yeptris::FFI::NODE_ALIAS => :alias,
  }.freeze

  def kind
    KINDS[alive { Yeptris::FFI.yeptris_node_kind(@c_ptr) }]
  end

  def scalar?
    kind == :scalar
  end

  def sequence?
    kind == :sequence
  end

  def mapping?
    kind == :mapping
  end

  def alias?
    kind == :alias
  end

  # Scalar content / alias name (UTF-8 String), nil for collections.
  def value
    len = ::FFI::MemoryPointer.new(:uint64)
    ptr = alive { Yeptris::FFI.yeptris_node_value(@c_ptr, len) }
    return nil if ptr.null?

    ptr.read_bytes(len.read_uint64).force_encoding(Encoding::UTF_8)
  end

  STYLES = {
    Yeptris::FFI::STYLE_PLAIN => :plain,
    Yeptris::FFI::STYLE_SINGLE_QUOTED => :single_quoted,
    Yeptris::FFI::STYLE_DOUBLE_QUOTED => :double_quoted,
    Yeptris::FFI::STYLE_LITERAL => :literal,
    Yeptris::FFI::STYLE_FOLDED => :folded,
  }.freeze

  def style
    STYLES[alive { Yeptris::FFI.yeptris_node_style(@c_ptr) }]
  end

  # Explicit tag URI when present, else nil.
  def tag
    len = ::FFI::MemoryPointer.new(:uint64)
    ptr = alive { Yeptris::FFI.yeptris_node_tag(@c_ptr, len) }
    return nil if ptr.null?

    ptr.read_bytes(len.read_uint64).force_encoding(Encoding::UTF_8)
  end

  def anchor
    len = ::FFI::MemoryPointer.new(:uint64)
    ptr = alive { Yeptris::FFI.yeptris_node_anchor(@c_ptr, len) }
    return nil if ptr.null?

    ptr.read_bytes(len.read_uint64).force_encoding(Encoding::UTF_8)
  end

  def alias_target
    t = alive { Yeptris::FFI.yeptris_node_alias_target(@c_ptr) }
    @document.wrap_node(t)
  end

  # ---- typed scalar reads (tag id decides eligibility) ----

  def to_i
    out = ::FFI::MemoryPointer.new(:int64)
    status = alive { Yeptris::FFI.yeptris_node_int(@c_ptr, out) }
    Yeptris::FFI.check_status(status, "yeptris_node_int")
    out.read_int64
  end

  def to_f
    out = ::FFI::MemoryPointer.new(:double)
    status = alive { Yeptris::FFI.yeptris_node_float(@c_ptr, out) }
    Yeptris::FFI.check_status(status, "yeptris_node_float")
    out.read_double
  end

  def to_bool
    out = ::FFI::MemoryPointer.new(:int)
    status = alive { Yeptris::FFI.yeptris_node_bool(@c_ptr, out) }
    Yeptris::FFI.check_status(status, "yeptris_node_bool")
    out.read_int != 0
  end

  TAGS = {
    Yeptris::FFI::TAG_STR => :str,
    Yeptris::FFI::TAG_INT => :int,
    Yeptris::FFI::TAG_FLOAT => :float,
    Yeptris::FFI::TAG_BOOL => :bool,
    Yeptris::FFI::TAG_NULL => :null,
    Yeptris::FFI::TAG_TIMESTAMP => :timestamp,
  }.freeze

  def tag_id
    TAGS[alive { Yeptris::FFI.yeptris_node_tag_id(@c_ptr) }]
  end

  # ---- sequence access ----

  def size
    case kind
    when :sequence then seq_count
    when :mapping then map_count
    else 1
    end
  end

  def seq_count
    alive { Yeptris::FFI.yeptris_node_seq_count(@c_ptr) }
  end

  def seq_at(index)
    @document.wrap_node(alive { Yeptris::FFI.yeptris_node_seq_at(@c_ptr, index) })
  end

  def each
    return enum_for(:each) unless block_given?
    raise Yeptris::Error, "#each is for sequences" unless sequence?

    (0...seq_count).each { |i| yield seq_at(i) }
  end

  # ---- mapping access ----

  def map_count
    alive { Yeptris::FFI.yeptris_node_map_count(@c_ptr) }
  end

  def [](key)
    raise Yeptris::Error, "#[] is for mappings" unless mapping?

    key = key.to_s
    @document.wrap_node(
      alive { Yeptris::FFI.yeptris_node_map_get(@c_ptr, key, key.bytesize) }
    )
  end

  def key?(key)
    !self[key].nil?
  end

  # Ordered [key, value] pairs.
  def each_pair
    return enum_for(:each_pair) unless block_given?
    raise Yeptris::Error, "#each_pair is for mappings" unless mapping?

    k = ::FFI::MemoryPointer.new(:pointer)
    v = ::FFI::MemoryPointer.new(:pointer)
    (0...map_count).each do |i|
      rc = alive { Yeptris::FFI.yeptris_node_map_at(@c_ptr, i, k, v) }
      next unless rc.zero?

      yield @document.wrap_node(k.read_pointer), @document.wrap_node(v.read_pointer)
    end
  end

  def keys
    # explicit block: two-arg yield + Symbol#to_proc would call
    # key.first(value) instead of taking the pair
    each_pair.map { |k, _v| k }
  end

  # ---- construction (TODO.impl/11 phase 3; errors raise) ----

  def map_add(key, node)
    key = key.to_s
    rc = alive { Yeptris::FFI.yeptris_node_map_add(@c_ptr, key, key.bytesize, node.c_ptr) }
    Yeptris::FFI.check_status(rc, "yeptris_node_map_add")
    self
  end

  def map_set(key, node)
    key = key.to_s
    rc = alive { Yeptris::FFI.yeptris_node_map_set(@c_ptr, key, key.bytesize, node.c_ptr) }
    Yeptris::FFI.check_status(rc, "yeptris_node_map_set")
    self
  end

  def map_del(key)
    key = key.to_s
    alive { Yeptris::FFI.yeptris_node_map_del(@c_ptr, key, key.bytesize) }.zero?
  end

  def seq_add(node)
    rc = alive { Yeptris::FFI.yeptris_node_seq_add(@c_ptr, node.c_ptr) }
    Yeptris::FFI.check_status(rc, "yeptris_node_seq_add")
    self
  end

  # Props on synthesized nodes (15's YAMLTree); values copied in.
  def set_anchor(name)
    alive { Yeptris::FFI.yeptris_node_set_anchor(@c_ptr, name, name.bytesize) }.zero?
  end

  def set_tag(tag)
    alive { Yeptris::FFI.yeptris_node_set_tag(@c_ptr, tag, tag.bytesize) }.zero?
  end

  def seq_del(index)
    alive { Yeptris::FFI.yeptris_node_seq_del(@c_ptr, index) }.zero?
  end

  # ---- Ruby materialization (Psych-compatible) ----

  # Materializes the subtree as native Ruby objects. Aliases preserve
  # object identity (the same Ruby object for every reference), keys
  # materialize with Psych's implicit typing (":sym" -> Symbol under
  # compat), and the anchor memo makes cycles defined by anchors safe.
  def node_id
    alive { Yeptris::FFI.yeptris_node_id(@c_ptr) }
  end

  def to_ruby(memo = nil)
    # readonly documents memoize per node: repeated materialization
    # of a shared subtree returns the SAME object at zero walk cost
    if @document.readonly?
      rm = @document.readonly_memo
      cached = rm[node_id]
      return cached if cached

      return rm[node_id] = to_ruby_walk({})
    end
    to_ruby_walk(memo || {})
  end

  def to_ruby_walk(memo)
    cached = memo[node_id]
    return cached if cached

    case kind
    when :mapping
      h = {}
      memo[node_id] = h
      each_pair do |k, v|
        h[k.to_ruby_key] = v.to_ruby(memo)
      end
      h
    when :sequence
      a = []
      memo[node_id] = a
      each { |e| a << e.to_ruby(memo) }
      a
    when :alias
      t = alias_target
      t.nil? ? nil : t.to_ruby(memo)
    else
      scalar_to_ruby
    end
  end

  # Mapping keys: Psych semantics — a plain scalar ":name" under the
  # compat schema scans to a Symbol; everything else materializes as
  # the scalar itself.
  def to_ruby_key
    symbol? ? symbolize : to_ruby
  end

  def scalar_to_ruby
    return symbolize if symbol? && tag_id == :str

    case tag_id
    when :null then nil
    when :bool then to_bool
    when :int then to_i
    when :float then to_f
    when :timestamp then ::Yeptris::Materializer.parse_timestamp(value)
    else value
    end
  end

  # Psych's ScalarScanner: plain ":name" (and ":", the null Symbol)
  # scans to a Symbol; quoting defeats it.
  def symbol?
    style == :plain && value&.start_with?(":") && !value.start_with?("::")
  end

  def symbolize
    v = value
    v.length <= 1 ? :"" : v[1..].to_sym
  end



  def alive
    @document.ensure_alive!
    yield
  end
end
