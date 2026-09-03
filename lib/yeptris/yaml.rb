# frozen_string_literal: true

module Yeptris
  # The neutral Ruby surface (the Psych-compat namespace arrives with
  # the recorder-driven Visitors in phase B; this is the yeptris-native
  # face users target first).
  module YAML
    module_function

    # Loads the FIRST document of a YAML stream as native Ruby objects.
    # schema: :compat_11 selects Psych/libyaml implicit typing
    # (yes/no, 0o/octal, sexagesimal); :core_12 (default) is YAML 1.2.
    def load(yaml, schema: :compat_11)
      Materializer.load(yaml, schema: schema)
    end

    # Every document in the stream, in order.
    def load_stream(yaml, schema: :compat_11)
      Materializer.load_stream(yaml, schema: schema)
    end

    # The Psych-suite port's spelling (spec/psych/): compat typing.
    def parse_yaml(yaml)
      load(yaml)
    end

    def load_file(path, schema: :compat_11)
      File.open(path, "rb") { |f| load(f, schema: schema) }
    end

    # Parses without materializing: the first document's root Node.
    def parse(yaml, schema: :core_12)
      doc = Document.parse(yaml, schema: schema)
      return nil if doc.document_count.zero?

      doc.root(0)
    end

    # Serializes a Ruby object graph to YAML via the DOM builder
    # (TODO.impl/11 phase 3). Strings are emitted plain only when the
    # resolver round-trips them as strings — everything else takes a
    # quoted style, so dump(load(x)) == x for the scalar types.
    def dump(obj, canonical: false)
      doc = Document.create
      root = Builder.build(doc, obj)
      doc.set_root(root) if root
      doc.serialize(canonical: canonical)
    ensure
      doc&.free
    end

    # From-scratch builder over the public construction API.
    module Builder
      module_function

      def build(doc, obj, seen = {})
        case obj
        when Hash then build_map(doc, obj, seen)
        when Array then build_seq(doc, obj, seen)
        when String then build_string(doc, obj)
        when Symbol then new_scalar(doc, ":#{obj}")
        when Integer, Float then new_scalar(doc, obj.to_s)
        when true, false then new_scalar(doc, obj.to_s)
        when nil then new_scalar(doc, "null")
        when Date, Time then new_scalar(doc, obj.iso8601)
        else
          raise DumpError,
                "cannot dump #{obj.class}: unsupported object " \
                "(custom to_yaml support lands with the Psych Visitors)"
        end
      end

      def build_map(doc, h, seen)
        cycle_guard(h, seen) do
          m = doc.new_mapping
          h.each { |k, v| m.map_add(key_text(k), build(doc, v, seen)) }
          m
        end
      end

      def build_seq(doc, a, seen)
        cycle_guard(a, seen) do
          s = doc.new_sequence
          a.each { |e| s.seq_add(build(doc, e, seen)) }
          s
        end
      end

      # A plain scalar that re-resolves to STR stays plain (nice
      # round-trips); anything ambiguous is double-quoted so the
      # reparse yields String again.
      def build_string(doc, s)
        n = new_scalar(doc, s)
        n.tag_id == :str ? n : new_scalar(doc, s, :force_str)
      end

      def key_text(k)
        k = ":#{k}" if k.is_a?(Symbol)
        k.to_s
      end

      def new_scalar(doc, text, mode = nil)
        doc.new_scalar(text.to_s,
                       mode == :force_str ? :double_quoted : :plain)
      end

      def cycle_guard(obj, seen)
        id = obj.object_id
        raise DumpError, "cycle detected: cannot dump recursive #{obj.class}" if seen[id]

        seen[id] = true
        out = yield
        seen.delete(id)
        out
      end
    end
  end
end
