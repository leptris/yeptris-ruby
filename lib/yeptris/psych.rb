# frozen_string_literal: true

require "date"
require "time"
require "set"

# The Psych drop-in namespace (TODO.impl/15 phase C).
#
# `require "yeptris/psych"` loads this namespace WITHOUT touching the
# top-level Psych constant (co-existence, issue #69); the process-
# exclusive drop-in rebind is `require "yeptris/psych/drop_in"` (the
# original stdlib, if loaded first, stays reachable as
# ::Psych::ORIGINAL). Semantics follow the Psych suite: load is
# SAFE by default (Psych 5 behavior — plain data only; anything
# tagged raises), unsafe_load materializes everything the yeptris
# loader understands, and parse returns the Nodes tree over the
# document without materializing.
module Yeptris
  module Psych
    # The tag registries (Psych's class-level API, #95 bug 4):
    # load_tags maps a serialized tag to the Class that revives it;
    # dump_tags overrides the emitted tag for a Class. Consulted by
    # the revival visitor (custom tags) and the dumper's tag choice.
    class << self
      def load_tags
        @load_tags ||= {}
      end

      def load_tags=(tags)
        @load_tags = tags
      end

      def dump_tags
        @dump_tags ||= {}
      end

      def dump_tags=(tags)
        @dump_tags = tags
      end

      # The third registry (stdlib psych carries all three; the rebind
      # broke relaton/lutaml callers that wrote it — the 26x
      # undefined-method report). Keys are normalized tag strings
      # ("tag:DOMAIN:TYPE"), values are [key, block] post-processors.
      def domain_types
        @domain_types ||= {}
      end

      def domain_types=(types)
        @domain_types = types
      end

      def add_domain_type(domain, type_tag, &block)
        key = ["tag", domain, type_tag].join(":")
        domain_types[key] = [key, block]
        domain_types["tag:#{type_tag}"] = [key, block]
      end

      def add_builtin_type(type_tag, &block)
        key = ["tag", "yaml.org,2002", type_tag].join(":")
        domain_types[key] = [key, block]
      end

      def remove_type(type_tag)
        domain_types.delete type_tag
      end

      def add_tag(tag, klass)
        load_tags[tag] = klass.name
        dump_tags[klass] = tag
      end
    end

    # Children load via autoload declared HERE — the immediate parent
    # namespace's file (never internal requires).
    autoload :Handler, "yeptris/psych/handler"
    # Handlers (the Recorder submodule) lives in handler.rb too — its
    # own entry so referencing Psych::Handlers triggers the load
    autoload :Handlers, "yeptris/psych/handler"
    autoload :Parser, "yeptris/psych/parser"
    autoload :CoderShim, "yeptris/psych/coder_shim"
    autoload :Visitors, "yeptris/psych/visitors"
    # The typed opt-in marker for arbitrary-object dump/load
    # (TODO.restructure/23). Eager by intent: classes include it at
    # declaration time, so the autoload must resolve before any
    # object instance exists.
    autoload :Encodable, "yeptris/psych/encodable"
    class Error < StandardError; end
    # Psych's exact interface (issue #32): same constructor arity,
    # same reader set (file/line/column/offset/problem/context), same
    # message shape — drop-in consumers' rescues and constructors
    # keep working after the rebind.
    class SyntaxError < Error
      attr_reader :file, :line, :column, :offset, :problem, :context

      def initialize(file = nil, line = 0, column = 0, offset = 0, problem = nil, context = nil)
        @file = file
        @line = line
        @column = column
        @offset = offset
        @problem = problem
        @context = context
        where = file ? "(#{file})" : "(<unknown>)"
        detail = context ? "#{problem} #{context}" : problem.to_s
        super("#{where}: #{detail} at line #{line} column #{column}")
      end

      # Structured lift from the C parser's message (carries
      # "line L, column C" detail).
      def self.from_parse_error(error)
        md = /\bline (\d+),? column (\d+)/.match(error.message)
        new(nil, md ? md[1].to_i : 0, md ? md[2].to_i : 0, 0, error.message)
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
    # Psych spells it Psych::AliasesError; the older name stays as an
    # alias for existing rescues.
    class AliasesError < Error; end
    AliasNotEnabled = AliasesError

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
        raise SyntaxError.from_parse_error(e)
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
        raise SyntaxError.from_parse_error(e)
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
          when nil, true, false, ::String, ::Integer, ::Float, ::Symbol, ::Date, ::Time
            Yeptris::YAML.dump(obj, header: true)
          else
            Visitors::YAMLTree.new.push(obj).finish
          end
        return out unless io

        io.write(out)
        io
      end

      private

      # yeptris materializes plain data only — there is nothing
      # unsafe it COULD load. The safety walk enforces Psych's
      # contract: aliases need opt-in, explicit non-core tags raise
      # DisallowedClass, and a scalar whose IMPLICIT typing yields a
      # class outside the permitted set raises too (issue #69: a
      # compat_11 date must not become a Date unless Date is
      # permitted — Psych::DisallowedClass semantics).
      def walk_safe(root, permitted, aliases_enabled)
        check(root, permitted, aliases_enabled) if root
        root.to_ruby
      end

      PERMITTED_BY_DEFAULT = [TrueClass, FalseClass, NilClass, Integer, Float,
                              String, Array, Hash].freeze

      def check(node, permitted, aliases_enabled)
        case node.kind
        when :alias
          raise AliasesError, "Unknown alias" unless aliases_enabled
        when :scalar, :mapping, :sequence
          tag = node.tag
          unless tag.nil?
            name = tag.split(":").last
            unless %w[str int float bool null timestamp seq map merge value
                      binary].include?(name)
              raise DisallowedClass, name
            end
          end
          if node.kind == :scalar && node.tag_id == :timestamp &&
             !permitted.include?(Date) && !permitted.include?(Time)
            raise DisallowedClass, "Date"
          end
          case node.kind
          when :mapping
            node.each_pair do |k, v|
              check(k, permitted, aliases_enabled)
              check(v, permitted, aliases_enabled)
            end
          when :sequence
            node.each { |e| check(e, permitted, aliases_enabled) }
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

# The drop-in is OPT-IN (issue #69): `require "yeptris/psych"` loads
# the namespace only and coexists with stdlib psych in ANY load
# order (this file never touches ::Psych). The rebind lives in
# yeptris/psych/drop_in — process-exclusive by nature, since the
# stdlib cannot be prevented from re-opening whatever ::Psych points
# at once IT loads.
# 0.4-contract migration signal (issue #95): this require used to
# rebind ::Psych. It does not anymore, and re-binding it here would
# regress #69 (any stdlib psych loaded afterwards would explode with
# a superclass mismatch), so the old path warns instead of acting.
if defined?(::Psych) && !::Psych.equal?(Yeptris::Psych)
  warn "yeptris: \"yeptris/psych\" defines the namespace only — it no " \
       "longer rebinds ::Psych. Require \"yeptris/psych/drop_in\" for the " \
       "drop-in rebind, or call Yeptris::Psych explicitly."
end
