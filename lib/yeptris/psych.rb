# frozen_string_literal: true

# The Psych drop-in namespace (TODO.impl/15 phase C).
#
# `require "yeptris/psych"` rebinds the top-level Psych constant to
# this module (the original, if any, stays reachable as
# ::Psych::ORIGINAL). Semantics follow the Psych suite: load is
# SAFE by default (Psych 5 behavior — plain data only; anything
# tagged raises), unsafe_load materializes everything the yeptris
# loader understands, and parse returns the Nodes tree over the
# document without materializing.
module Yeptris
  module Psych
    # Children load via autoload declared HERE — the immediate parent
    # namespace's file (never internal requires).
    autoload :Handler, "yeptris/psych/handler"
    # Handlers (the Recorder submodule) lives in handler.rb too — its
    # own entry so referencing Psych::Handlers triggers the load
    autoload :Handlers, "yeptris/psych/handler"
    autoload :Parser, "yeptris/psych/parser"
    autoload :CoderShim, "yeptris/psych/coder_shim"
    autoload :Visitors, "yeptris/psych/visitors"
    class Error < StandardError; end
    class SyntaxError < Error
      attr_reader :line, :column

      def initialize(message, line = 0, column = 0)
        super(message)
        @line = line
        @column = column
      end
    end
    class BadAlias < Error; end
    class DisallowedClass < Error
      attr_reader :name

      def initialize(name)
        super("Tried to load unspecified class: #{name}")
        @name = name
      end
    end
    class AliasNotEnabled < Error; end

    class << self
      # Psych 5: load is safe — plain data structures only. Tagged
      # nodes raise DisallowedClass unless their class is permitted
      # (Date/Time/Symbol are built in; they are plain data here).
      def load(yaml, permitted_classes: [], aliases: false, **)
        safe_load(yaml, permitted_classes: permitted_classes, aliases: aliases)
      end

      # Full revival over the Nodes tree: !ruby/object, !ruby/struct,
      # !ruby/set, encode_with/init_with, alias identity. Plain-data
      # loads should use load/safe_load (the Materializer fast path).
      def unsafe_load(yaml, **)
        tree = parse(yaml)
        return nil if tree.nil?

        Visitors::ToRuby.visit(tree.children.first)
      end

      def safe_load(yaml, permitted_classes: [], aliases: false, **)
        doc = Yeptris::Document.parse(yaml, schema: :compat_11)
        begin
          walk_safe(doc.root(0), permitted_classes, aliases)
        ensure
          doc.free
        end
      end

      # The first document's node tree (no Ruby materialization).
      def parse(yaml)
        doc = Yeptris::Document.parse(yaml, schema: :compat_11)
        return nil if doc.document_count.zero?

        Nodes::Builder.document(doc)
      rescue Yeptris::ParseError => e
        raise SyntaxError, e.message
      end

      def parse_stream(yaml)
        doc = Yeptris::Document.parse(yaml, schema: :compat_11)
        return nil if doc.document_count.zero?

        stream = Nodes::Stream.new
        (0...doc.document_count).each do |i|
          stream.children << Nodes::Builder.document_stream_child(doc, i)
        end
        stream.owner = doc
        ObjectSpace.define_finalizer(
          stream, proc { doc.free unless doc.freed? }
        )
        stream
      rescue Yeptris::ParseError => e
        raise SyntaxError, e.message
      ensure
        doc&.free if doc && !stream
      end

      # Arbitrary object graphs through the YAMLTree visitor
      # (anchors, !ruby/ tags); plain data rides the fast builder.
      def dump(obj, io = nil)
        # scalars take the fast builder; EVERYTHING else (including
        # plain containers — they may nest custom objects) goes
        # through the visitor, which builds the same DOM for plain
        # data anyway
        out =
          case obj
          when nil, true, false, String, Integer, Float, Symbol, Date, Time
            Yeptris::YAML.dump(obj)
          else
            Visitors::YAMLTree.new.push(obj).finish
          end
        return out unless io

        io.write(out)
        io
      end

      private

      # yeptris materializes plain data only — there is nothing
      # unsafe it COULD load. The safety walk enforces what Psych
      # enforces on such documents: aliases need opt-in, and explicit
      # non-core tags raise DisallowedClass (the only "classes" the
      # loader can produce are core-schema types, all permitted).
      def walk_safe(root, permitted, aliases_enabled)
        check(root, aliases_enabled) if root
        root.to_ruby
      end

      def check(node, aliases_enabled)
        case node.kind
        when :alias
          raise AliasNotEnabled, "Unknown alias" unless aliases_enabled
        when :scalar, :mapping, :sequence
          tag = node.tag
          unless tag.nil?
            name = tag.split(":").last
            unless %w[str int float bool null timestamp seq map merge value
                      binary].include?(name)
              raise DisallowedClass, name
            end
          end
          case node.kind
          when :mapping
            node.each_pair do |k, v|
              check(k, aliases_enabled)
              check(v, aliases_enabled)
            end
          when :sequence
            node.each { |e| check(e, aliases_enabled) }
          end
        end
      end
    end

    # Psych::Nodes over the yeptris document: the tree IS the parsed
    # document (children are node handles, not copies) — parse cost
    # is the parse, and to_ruby reuses the Materializer.
    module Nodes
      class Node
        include Enumerable

        attr_reader :children
        attr_reader :handle # @api private — the Yeptris::Node
        # @api private — the tree builder attaches handles; a writer,
        # never instance_variable_set from outside
        attr_writer :handle
        # The Document owning this tree's C memory; a plain writer —
        # never instance_variable_set from outside (encapsulation law).
        attr_accessor :owner

        def initialize(handle = nil, children = [])
          @handle = handle
          @children = children
        end

        # Every node HAS an anchor concept (none by default) — the
        # anchored search needs no type probe, just the model.
        def anchor
          nil
        end

        def each(&block)
          @children.each(&block)
        end

        # The Ruby object for this subtree (Materializer semantics).
        def to_ruby
          @handle.to_ruby
        end
      end

      class Stream < Node
        def free
          @owner&.free
        end
      end

      # Owns the underlying Yeptris::Document: node handles in the
      # tree stay valid while the tree is reachable; a GC finalizer
      # releases the C memory when it is not.
      class Document < Node
        attr_reader :version, :tags

        def initialize(version = [], tags = {})
          super(nil)
          @version = version
          @tags = tags
        end

        # @api private — transfer of C ownership to this tree
        def own(yeptris_doc)
          @owner = yeptris_doc
          ObjectSpace.define_finalizer(
            self, proc { yeptris_doc.free unless yeptris_doc.freed? }
          )
          self
        end

        def free
          @owner&.free
        end
      end

      class Scalar < Node
        attr_reader :value, :tag, :anchor, :plain, :quoted, :style

        def initialize(value = nil, anchor: nil, tag: nil, plain: true,
                       quoted: false, style: :plain)
          super(nil)
          @value = value
          @anchor = anchor
          @tag = tag
          @plain = plain
          @quoted = quoted
          @style = style
        end
      end

      class Sequence < Node
        attr_reader :anchor, :tag, :style

        def initialize(anchor: nil, tag: nil, style: :block)
          super(nil, [])
          @anchor = anchor
          @tag = tag
          @style = style
        end
      end

      class Mapping < Node
        attr_reader :anchor, :tag, :style

        def initialize(anchor: nil, tag: nil, style: :block)
          super(nil, [])
          @anchor = anchor
          @tag = tag
          @style = style
        end
      end

      class Alias < Node
        attr_reader :anchor

        def initialize(anchor)
          super(nil)
          @anchor = anchor
        end
      end

      # Builds the Nodes tree from a parsed document.
      module Builder
        module_function

        # parse(): one document, owning the yeptris document
        def document(doc, index = 0)
          document_stream_child(doc, index).own(doc)
        end

        # parse_stream(): a child document sharing one owner (the
        # stream owns the yeptris document)
        def document_stream_child(doc, index)
          root = doc.root(index)
          d = Document.new
          d.handle = root&.document
          d.children << node(root) if root
          d
        end

        def node(n)
          case n.kind
          when :mapping
            m = Mapping.new(anchor: n.anchor, tag: n.tag)
            n.each_pair do |k, v|
              m.children << node(k)
              m.children << node(v)
            end
            m.handle = n
            m
          when :sequence
            s = Sequence.new(anchor: n.anchor, tag: n.tag)
            n.each { |e| s.children << node(e) }
            s.handle = n
            s
          when :alias
            a = Alias.new(n.value)
            a.handle = n
            a
          else
            sc = Scalar.new(n.value, anchor: n.anchor, tag: n.tag,
                                  plain: n.style == :plain, style: n.style)
            sc.handle = n
            sc
          end
        end
      end
    end
  end
end

# The drop-in: rebind the top-level constant ( Psych-stdlib, if
# already loaded, stays reachable as Yeptris::Psych::ORIGINAL).
if defined?(::Psych) && !::Psych.equal?(Yeptris::Psych) &&
   !Yeptris::Psych.const_defined?(:ORIGINAL, false)
  Yeptris::Psych.const_set(:ORIGINAL, ::Psych)
end
# class_eval reaches Module-private methods WITHOUT send (the law:
# no send to private methods); remove_const has no public form, and
        # the rebind is this namespace's whole purpose
        Object.class_eval { remove_const(:Psych) } if defined?(::Psych)
::Psych = Yeptris::Psych
