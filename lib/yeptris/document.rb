# frozen_string_literal: true

class Yeptris::Document
  attr_reader :c_ptr

  # Shared between the instance and its GC finalizer (Procs close over
  # variables by reference) — the leptris-ruby double-free fix: the
  # explicit free path and the finalizer both flip the same flag.
  Freed = Struct.new(:state) # :alive | :freed

  def initialize(c_ptr = nil, freed = Freed.new(:alive))
    @c_ptr = c_ptr
    @freed = freed
    @readonly = false
    # Strong wrapper cache keyed on the C node address: the same C node
    # always yields the same Ruby object (identity for aliases/eql?),
    # cleared at free — no stale entries, no GC-race weak maps.
    @wrapper_cache = {}
    ObjectSpace.define_finalizer(self, self.class.finalize(c_ptr, freed)) unless c_ptr.null?
  end

  def self.parse(yaml, schema: :core_12, max_depth: 0)
    yaml = yaml.read if yaml.respond_to?(:read)
    yaml = yaml.to_s
    doc =
      if schema == :core_12 && max_depth.zero?
        Yeptris::FFI.yeptris_parse(yaml, yaml.bytesize, nil)
      else
        opts = Yeptris::FFI::ParseOptions.new
        opts[:schema] = schema == :compat_11 ? Yeptris::FFI::SCHEMA_11_COMPAT : Yeptris::FFI::SCHEMA_12_CORE
        opts[:max_depth] = max_depth
        Yeptris::FFI.yeptris_parse_ex(yaml, yaml.bytesize, opts, nil)
      end
    if doc.null?
      # the status out-param is skipped: the thread-local error
      # channel carries the failure detail (measurable on small docs)
      raise Yeptris::ParseError,
            "parse failed: #{Yeptris::FFI.last_error_message}"
    end
    wrap(doc)
  end

  def self.parse_json(json)
    json = json.read if json.respond_to?(:read)
    json = json.to_s
    doc = Yeptris::FFI.yeptris_parse_json(json, json.bytesize, nil)
    raise Yeptris::ParseError,
          "json parse failed: #{Yeptris::FFI.last_error_message}" if doc.null?

    wrap(doc)
  end

  # An empty document for from-scratch construction (TODO.impl/11 p3).
  def self.create
    doc = Yeptris::FFI.yeptris_document_new
    raise Yeptris::Error, "yeptris_document_new failed" if doc.null?

    wrap(doc)
  end

  # @api private
  def self.wrap(c_ptr)
    new(c_ptr)
  end

  def ensure_alive!
    raise Yeptris::FreedError, "document is freed" if @freed.state == :freed
  end

  def free
    return if @freed.state == :freed

    @freed.state = :freed
    @wrapper_cache.clear
    Yeptris::FFI.yeptris_document_free(@c_ptr)
  end

  def freed?
    @freed.state == :freed
  end

  def readonly!
    @readonly = true
    self
  end

  def readonly?
    @readonly
  end

  # @api private — memo table for readonly materialization: node ids
  # that already produced their Ruby object keep it (leptris pattern:
  # readonly documents never change, so the memo is forever valid).
  def readonly_memo
    @readonly_memo ||= {}
  end

  # @api private — the single Node construction path. Query handles
  # are transient C allocations; the wrapper cache is keyed on the
  # STABLE node id (yeptris_node_id), so the same node always yields
  # the same Ruby object no matter which query produced the handle.
  def wrap_node(c_ptr)
    ensure_alive!
    return nil if c_ptr.null?

    id = Yeptris::FFI.yeptris_node_id(c_ptr)
    @wrapper_cache[id] ||= Yeptris::Node.new(c_ptr, self)
  end

  def document_count
    ensure_alive!
    Yeptris::FFI.yeptris_document_count(@c_ptr)
  end

  # Root node of stream document i (0-based).
  def root(index = 0)
    ensure_alive!
    wrap_node(Yeptris::FFI.yeptris_document_root(@c_ptr, index))
  end

  def serialize(canonical: false, best_width: 0)
    ensure_alive!
    len = ::FFI::MemoryPointer.new(:uint64)
    ptr =
      if canonical || best_width.positive?
        opts = Yeptris::FFI::EmitOptions.new
        opts[:size] = Yeptris::FFI::EmitOptions.size
        opts[:canonical] = canonical ? 1 : 0
        opts[:best_width] = best_width
        Yeptris::FFI.yeptris_serialize_ex(@c_ptr, opts, len)
      else
        Yeptris::FFI.yeptris_serialize(@c_ptr, len)
      end
    Yeptris::FFI::Owned.string(ptr, len)
  end

  def serialize_json
    ensure_alive!
    len = ::FFI::MemoryPointer.new(:uint64)
    Yeptris::FFI::Owned.string(Yeptris::FFI.yeptris_serialize_json(@c_ptr, len), len)
  end

  def to_s
    serialize
  end

  # The Ruby object graph of stream document i (Psych-compatible
  # materialization; alias identity preserved via the memo).
  def to_ruby(index = 0)
    ensure_alive!
    r = root(index)
    r.nil? ? nil : r.to_ruby
  end

  # ---- construction conveniences (TODO.impl/11 phase 3) ----

  def new_mapping
    ensure_alive!
    wrap_node(Yeptris::FFI.yeptris_node_new_mapping(@c_ptr)) or
      raise Yeptris::Error, "yeptris_node_new_mapping failed"
  end

  def new_sequence
    ensure_alive!
    wrap_node(Yeptris::FFI.yeptris_node_new_sequence(@c_ptr)) or
      raise Yeptris::Error, "yeptris_node_new_sequence failed"
  end

  # style: :plain / :single_quoted / :double_quoted / :literal / :folded.
  # The value is copied into the document (nothing is borrowed).
  def new_scalar(text, style = :plain)
    ensure_alive!
    code = Yeptris::Node::STYLES.key(style) or
      raise ArgumentError, "unknown scalar style #{style.inspect}"
    text = text.to_s
    n = Yeptris::FFI.yeptris_node_new_scalar(@c_ptr, text, text.bytesize, code)
    wrap_node(n) or raise Yeptris::Error, "yeptris_node_new_scalar failed"
  end

  # An alias node: display name + the target it resolves to.
  def new_alias(target, name)
    ensure_alive!
    n = Yeptris::FFI.yeptris_node_new_alias(@c_ptr, target.c_ptr, name, name.bytesize)
    wrap_node(n) or raise Yeptris::Error, "yeptris_node_new_alias failed"
  end

  def set_root(node)
    ensure_alive!
    rc = Yeptris::FFI.yeptris_document_set_root(@c_ptr, node.c_ptr)
    Yeptris::FFI.check_status(rc, "yeptris_document_set_root")
    self
  end

  # GC safety net: an explicit #free already ran is fine; a miss here
  # frees C memory that would otherwise leak.
  def self.finalize(c_ptr, freed)
    proc do
      Yeptris::FFI.yeptris_document_free(c_ptr) if freed.state == :alive
      freed.state = :freed
    end
  end
end
