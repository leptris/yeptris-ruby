# frozen_string_literal: true

# The YAML leg of the Descriptor plan walk (yeptris#293 slice three,
# over the C DOM plan walk of libyeptris v0.6.4): the same compiled
# row shape as Yeptris::JSON::Descriptor, applied to a parsed YAML
# document — block YAML hydrates to typed columns with no
# intermediate Ruby tree.
#
#     descriptor = Yeptris::YAML::Descriptor.build(
#       kind: :map, path: ["data", "items"], # segmented paths work
#       children: [{ name: "id", kind: :int }, { name: "name", kind: :str }])
#     descriptor.walk(yaml).column("id") # => [1, 2, ...]
#
# Typed extraction rides the parse-time tag ids (schema: selects the
# resolver — :compat_11 keeps the Psych/libyaml implicit typing
# YAML.load uses); string columns are materialized from the
# document's regions before the result returns (nothing borrowed).
class Yeptris::YAML::Descriptor < ::Yeptris::JSON::Descriptor
  # schema: :core_12 (YAML 1.2) or :compat_11 (the Psych-compatible
  # implicit typing Yeptris::YAML.load uses).
  def initialize(handle, names, schema)
    super(handle, names)
    @schema = schema
  end

  # @api private — the compile rides the JSON Descriptor's grammar
  # (inherited private class method); schema selects the resolver
  def self.build(kind:, path: nil, children:, schema: :compat_11)
    handle, names = compile_handle(kind, path, children)
    new(handle, names, schema)
  end

  def walk(yaml)
    src = ::Yeptris.read_input(yaml).to_s
    doc = ::Yeptris::Document.parse(src, schema: @schema)
    return [] if doc.nil? # the legal empty stream

    begin
      st = ::FFI::MemoryPointer.new(:int)
      raw = ::Yeptris::FFI.yeptris_document_plan_walk(doc.c_ptr, @handle, st)
      if raw.null?
        raise ::Yeptris::JSON::Descriptor::Error,
              "plan walk failed (status=#{st.read_int}) — the document shape " \
              "disagrees with the plan"
      end

      begin
        ::Yeptris::JSON::Descriptor::PlanResult.read_dom(raw, @names)
      ensure
        ::Yeptris::FFI.yeptris_plan_result_free(raw)
      end
    ensure
      doc.free
    end
  end
end
