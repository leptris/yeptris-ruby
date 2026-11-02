# frozen_string_literal: true

module Yeptris
  # The validation face (engine validate.h; issue #882, binding
  # TODO item 6). Two checks over one engine pass:
  #
  #   * the SCHEMA-FAMILY walk (`validate` with a schema symbol) —
  #     explicit-tag consistency, mapping-key uniqueness by canonical
  #     form, and (under :json_12) the spec 10.2 JSON-production rules;
  #   * JSON SCHEMA draft 2020-12 (`validate` with `json_schema:`) —
  #     one-shot over schema bytes, or against a compiled
  #     {Yeptris::Validation::Schema} handle (parse once, validate
  #     many; #885 item 3).
  #
  # Diagnostics cross the FFI boundary once, as plain Ruby values
  # ({Diagnostic}): no C pointer ever leaks out of this module.
  module Validation
    # Raised for an instance that carries diagnostics. The full report
    # rides `diagnostics` (plain {Diagnostic} values, never pointers).
    class Error < ::Yeptris::Error
      attr_reader :diagnostics

      def initialize(diagnostics)
        @diagnostics = diagnostics
        first = diagnostics.first
        detail = first ? "#{first.keyword} at #{first.path}: #{first.detail}" : "no diagnostics"
        super("validation failed (#{diagnostics.size} diagnostics): #{detail}")
      end
    end

    # The code -> keyword table (validate.h's YeptrisDiagCode). The
    # 2020-12 walk's codes name their JSON Schema keyword; the
    # schema-family walk's codes name the violated YAML rule.
    KEYWORD = {
      FFI::DIAG_NONE => "none",
      FFI::DIAG_TAG_MISMATCH => "tag-mismatch",
      FFI::DIAG_KEY_NOT_STRING => "key-not-string",
      FFI::DIAG_NON_JSON_TYPE => "non-json-type",
      FFI::DIAG_DUPLICATE_KEY => "duplicate-key",
      FFI::DIAG_TYPE => "type",
      FFI::DIAG_REQUIRED => "required",
      FFI::DIAG_ENUM => "enum",
      FFI::DIAG_CONST => "const",
      FFI::DIAG_PATTERN => "pattern",
      FFI::DIAG_MINIMUM => "minimum",
      FFI::DIAG_MAXIMUM => "maximum",
      FFI::DIAG_EXCLUSIVE_MINIMUM => "exclusiveMinimum",
      FFI::DIAG_EXCLUSIVE_MAXIMUM => "exclusiveMaximum",
      FFI::DIAG_MIN_LENGTH => "minLength",
      FFI::DIAG_MAX_LENGTH => "maxLength",
      FFI::DIAG_MIN_ITEMS => "minItems",
      FFI::DIAG_MAX_ITEMS => "maxItems",
      FFI::DIAG_UNIQUE_ITEMS => "uniqueItems",
      FFI::DIAG_ADDITIONAL_PROPERTY => "additionalProperties",
      FFI::DIAG_ANY_OF => "anyOf",
      FFI::DIAG_ONE_OF => "oneOf",
      FFI::DIAG_NOT => "not",
      FFI::DIAG_REF => "$ref",
      FFI::DIAG_FALSE_SCHEMA => "false",
      FFI::DIAG_DEPTH => "depth",
      FFI::DIAG_LIMIT => "limit",
      FFI::DIAG_MULTIPLE_OF => "multipleOf",
      FFI::DIAG_MIN_PROPERTIES => "minProperties",
      FFI::DIAG_MAX_PROPERTIES => "maxProperties",
      FFI::DIAG_CONTAINS => "contains",
      FFI::DIAG_MIN_CONTAINS => "minContains",
      FFI::DIAG_MAX_CONTAINS => "maxContains",
      FFI::DIAG_DEPENDENT_REQUIRED => "dependentRequired",
    }.freeze

    # One structured diagnostic: the engine's yeptris_diagnostic read
    # into plain Ruby at drain time (a value class — ==, eql?, hash —
    # never an FFI wrapper).
    class Diagnostic
      attr_reader :code, :path, :detail, :line, :col, :offset

      def initialize(code:, path:, detail:, line: 0, col: 0, offset: 0)
        @code = code
        @path = path
        @detail = detail
        @line = line
        @col = col
        @offset = offset
      end

      # The violated keyword ("type", "minimum", "duplicate-key", ...).
      def keyword
        KEYWORD.fetch(code, "unknown-#{code}")
      end

      # The JSON-pointer instance path ("/a/b/0", ~0/~1 escaped) split
      # into its unescaped segments; the root is [].
      def path_array
        return [] if path.empty?

        path.split("/")[1..].map { |s| s.gsub("~1", "/").gsub("~0", "~") }
      end

      # The engine's bounded explanation ("3 is less than the minimum 10").
      def message
        detail
      end

      alias to_s message

      def ==(other)
        other.is_a?(Diagnostic) && code == other.code && path == other.path &&
          detail == other.detail && line == other.line && col == other.col &&
          offset == other.offset
      end
      alias eql? ==

      def hash
        [code, path, detail, line, col, offset].hash
      end

      def to_h
        { code: code, keyword: keyword, path: path, path_array: path_array,
          detail: detail, message: message, line: line, col: col, offset: offset }
      end

      def inspect
        "#<#{self.class.name} #{keyword} path=#{path.inspect} line=#{line} " \
          "col=#{col} detail=#{detail.inspect}>"
      end
    end

    # The compiled schema (yeptris_schema_compile): the schema bytes,
    # its DOM, and the pattern kernel's programs retained behind one
    # opaque handle — parse ONCE, validate many streams against it.
    # Ownership mirrors Yeptris::Document: an explicit #free and a GC
    # finalizer flip the same freed flag (the pointer-only finalizer —
    # it captures the raw address, never the wrapper, so no
    # use-after-free race).
    class Schema
      # Shared between the instance and its finalizer (the
      # leptris-ruby double-free fix).
      Freed = Struct.new(:state) # :alive | :freed

      attr_reader :c_ptr

      # Compiles JSON Schema bytes (JSON is YAML flow — a YAML-shaped
      # mapping schema compiles too). Raises ArgumentError for empty
      # bytes (the engine's "hold no document") and ParseError for
      # bytes that do not parse.
      def self.compile(bytes)
        raise ::ArgumentError, "schema bytes are required" if bytes.nil?
        bytes = ::Yeptris.read_input(bytes).to_s
        raise ::ArgumentError, "schema bytes hold no document" if bytes.empty?

        ptr = FFI.yeptris_schema_compile(bytes, bytes.bytesize)
        raise ::Yeptris::ParseError,
              "schema compile failed: #{FFI.last_error_message}" if ptr.null?

        new(ptr)
      end

      # Block form: the handle frees when the block exits (valid or not).
      def self.open(bytes)
        schema = compile(bytes)
        begin
          yield schema
        ensure
          schema.free
        end
      end

      # @api private — produced by .compile; a raw pointer argument is
      # not a caller surface (the same contract as Document).
      def initialize(c_ptr)
        unless c_ptr.is_a?(::FFI::Pointer)
          raise ArgumentError,
                "a schema FFI pointer is required — build schemas with " \
                "Yeptris::Validation::Schema.compile"
        end

        @c_ptr = c_ptr
        @freed = Freed.new(:alive)
        ObjectSpace.define_finalizer(self, self.class.finalize(c_ptr)) unless c_ptr.null?
      end

      # Validates one instance stream against the retained model.
      # Returns the diagnostics array (empty = valid).
      def validate(bytes)
        ensure_alive!
        bytes = ::Yeptris.read_input(bytes).to_s
        report = ::FFI::MemoryPointer.new(:pointer)
        st = FFI.yeptris_schema_validate(@c_ptr, bytes, bytes.bytesize, report)
        Validation.consume_report(st, report, "schema validate")
      end

      def valid?(bytes)
        validate(bytes).empty?
      end

      def ensure_alive!
        raise ::Yeptris::FreedError, "schema is freed" if @freed.state == :freed
      end

      def free
        return if @freed.state == :freed

        @freed.state = :freed
        ObjectSpace.undefine_finalizer(self)
        FFI.yeptris_schema_free(@c_ptr)
      end

      def freed?
        @freed.state == :freed
      end

      # Pointer-only finalizer (Document's law): no Ruby objects, no
      # wrapper — a finalizer closing over the wrapper races its sweep.
      def self.finalize(c_ptr)
        proc { FFI.yeptris_schema_free(c_ptr) }
      end
    end

    class << self
      # The schema-family walk over the engine's own front door
      # (encodings, BOM, every document of the stream). schema: one of
      # :core_12, :compat_11, :json_12. Returns the diagnostics array.
      def validate_family(bytes, schema: :core_12)
        require_engine!
        bytes = ::Yeptris.read_input(bytes).to_s
        report = ::FFI::MemoryPointer.new(:pointer)
        st = FFI.yeptris_validate(bytes, bytes.bytesize, schema_id(schema), report)
        consume_report(st, report, "validate")
      end

      # JSON Schema validation: `schema` is a compiled
      # {Yeptris::Validation::Schema} (validate many) or schema bytes
      # (one-shot). Returns the diagnostics array.
      def validate_schema(bytes, schema)
        require_engine!
        case schema
        when Schema then schema.validate(bytes)
        when String then one_shot(bytes, schema)
        else
          raise ::ArgumentError,
                "json_schema: must be a Yeptris::Validation::Schema or schema " \
                "bytes (got #{schema.class})"
        end
      end

      # The engine's whole-report drain shared by every face: maps the
      # status, drains the diagnostics into plain values, frees the
      # report — exactly once, on every path.
      def consume_report(status, report, action)
        ptr = report.read_pointer
        diags = drain_report(ptr)
        return diags if status == FFI::OK || status == FFI::SCHEMA_ERROR

        raise ::ArgumentError, "#{action}: #{FFI.last_error_message}" if status == FFI::ERROR_ARG

        raise ::Yeptris::ParseError, "#{action} failed: #{FFI.last_error_message}"
      ensure
        FFI.yeptris_validate_report_free(ptr) unless ptr.null?
      end

      # The schema symbol -> YeptrisSchema id (resolve.h's enum) for
      # the VALIDATION family walks: only the YAML 1.2 families are
      # validation families — the engine rejects :compat_11 with
      # "schema 1 is not a validation family", surfaced here as the
      # same ArgumentError the other bad symbols take.
      def schema_id(name)
        case name
        when :core_12 then FFI::SCHEMA_12_CORE
        when :json_12 then FFI::SCHEMA_12_JSON
        when :compat_11
          raise ::ArgumentError,
                "schema: :compat_11 is not a validation family — the walk " \
                "covers the YAML 1.2 families (:core_12, :json_12)"
        else
          raise ::ArgumentError,
                "schema: must be :core_12, :compat_11, or :json_12 (got #{name.inspect})"
        end
      end

      private

      def one_shot(bytes, schema_bytes)
        bytes = ::Yeptris.read_input(bytes).to_s
        schema_bytes = schema_bytes.to_s
        report = ::FFI::MemoryPointer.new(:pointer)
        st = FFI.yeptris_json_schema_validate(schema_bytes, schema_bytes.bytesize,
                                              bytes, bytes.bytesize, report)
        consume_report(st, report, "json schema validate")
      end

      # drain before free: the diagnostics are read into plain Ruby
      # while the report is still alive. The texts re-tag UTF-8 (the
      # binding's string discipline — #135: engine materializations
      # ride UTF-8, not the raw BINARY read).
      def drain_report(report)
        return [] if report.null?

        FFI.yeptris_validate_report_count(report).times.map do |i|
          d = FFI::CDiagnostic.new(FFI.yeptris_validate_report_at(report, i))
          Diagnostic.new(
            code: d[:code],
            path: d.pointer.get_string(FFI::CDiagnostic.offset_of(:path))
                     .force_encoding(::Encoding::UTF_8),
            detail: d.pointer.get_string(FFI::CDiagnostic.offset_of(:detail))
                      .force_encoding(::Encoding::UTF_8),
            line: d[:line], col: d[:col], offset: d[:offset]
          )
        end
      end

      def require_engine!
        return if FFI::VALIDATION

        raise ::Yeptris::Error,
              "yeptris: the validation face needs libyeptris 0.6.59+; the " \
              "loaded library predates it. Update the engine library."
      end
    end
  end
end
