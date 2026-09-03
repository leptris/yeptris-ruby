# frozen_string_literal: true

require "date"
require "time"
require "set"

module Yeptris
  module Psych
    module Visitors
      # The dump-side visitor (Psych's YAMLTree core): an arbitrary
      # Ruby object graph becomes DOM nodes — anchors for shared
      # objects, aliases for repeats, encode_with support, and the
      # !ruby/... tags Psych's own emitter produces.
      class YAMLTree
        def initialize
          @tree = ::Yeptris::Document.create
          @names = {}  # object_id -> anchor name
          @counter = 0
        end

        def push(obj)
          @refs = Hash.new(0)
          @refs[obj.object_id] += 1 # the root counts as a reference
          count_refs(obj, {})
          root = visit(obj)
          @tree.set_root(root) if root
          self
        end

        def finish
          @tree.serialize
        end

        def visit(obj)
          case obj
          when nil, true, false, Integer, Float, String then scalar(obj)
          when Symbol then scalar(":#{obj}")
          when Date, Time then scalar(obj) # timestamp text, never ivars
          when Hash then visit_hash(obj)
          when Array then visit_array(obj)
          when Struct then visit_struct(obj)
          when Set then visit_set(obj)
          else
            if obj.respond_to?(:encode_with)
              visit_encode_with(obj)
            else
              visit_object(obj)
            end
          end
        end

        private

        # Psych anchors only objects that appear more than once;
        # single-occurrence containers dump clean (no &o1 noise)
        def anchor_for(obj)
          oid = obj.object_id
          name = @names[oid]
          return [:alias, name] if name

          if @refs[oid] < 2
            return [:none, nil]
          end
          name = "o#{@counter += 1}"
          @names[oid] = name
          [:new, name]
        end

        def count_refs(obj, seen)
          return if seen.key?(obj.object_id)

          seen[obj.object_id] = true
          case obj
          when Hash
            obj.each_value { |v| @refs[v.object_id] += 1; count_refs(v, seen) }
          when Array
            obj.each { |v| @refs[v.object_id] += 1; count_refs(v, seen) }
          when Struct
            obj.each_pair { |_k, v| @refs[v.object_id] += 1; count_refs(v, seen) }
          when Set
            obj.each { |v| @refs[v.object_id] += 1; count_refs(v, seen) }
          when String, Integer, Float, Symbol, Date, Time, true, false, nil, Numeric
            # immutables: identity anchors are meaningless
          else
            if obj.respond_to?(:encode_with)
              # coder contents are opaque here; the object itself may
              # repeat — count it from the caller side only
            else
              obj.instance_variables.each do |iv|
                v = obj.instance_variable_get(iv)
                @refs[v.object_id] += 1
                count_refs(v, seen)
              end
            end
          end
        end

        def scalar(obj, tag: nil)
          # strings route through the builder's plain-safety helper
          # (one quoting rule, DRY); other scalars are their own text
          text =
            if obj.is_a?(Date) || obj.is_a?(Time)
              obj.iso8601 # canonical timestamp form, not to_s
            else
              obj.nil? ? "null" : obj.to_s
            end
          n =
            if obj.is_a?(String)
              ::Yeptris::YAML::Builder.build_string(@tree, obj)
            else
              @tree.new_scalar(text, :plain)
            end
          n.set_tag(tag) if tag
          n
        end

        def visit_hash(hash)
          state, name = anchor_for(hash)
          return alias_of(hash, name) if state == :alias

          m = @tree.new_mapping
          remember(hash, m)
          m.set_anchor(name) if name
          hash.each { |k, v| m.map_add(key_text(k), visit(v)) }
          m
        end

        def visit_array(ary)
          state, name = anchor_for(ary)
          return alias_of(ary, name) if state == :alias

          s = @tree.new_sequence
          remember(ary, s)
          s.set_anchor(name) if name
          ary.each { |e| s.seq_add(visit(e)) }
          s
        end

        def visit_struct(strct)
          state, name = anchor_for(strct)
          return alias_of(strct, name) if state == :alias

          m = @tree.new_mapping
          remember(strct, m)
          m.set_anchor(name) if name
          m.set_tag(strct.class.name ? "!ruby/struct:#{strct.class.name}" : "!ruby/struct")
          strct.each_pair { |k, v| m.map_add(key_text(k), visit(v)) }
          m
        end

        def visit_set(set)
          state, name = anchor_for(set)
          return alias_of(set, name) if state == :alias

          s = @tree.new_sequence
          remember(set, s)
          s.set_anchor(name) if name
          s.set_tag("!ruby/set")
          set.each { |e| s.seq_add(visit(e)) }
          s
        end

        def visit_encode_with(obj)
          state, name = anchor_for(obj)
          return alias_of(obj, name) if state == :alias

          coder = ::Yeptris::Psych::CoderShim.new(obj.class.name)
          obj.encode_with(coder)
          node =
            case coder.type
            when :scalar then scalar(coder.scalar, tag: coder.tag)
            when :seq
              s = @tree.new_sequence
              s.set_tag(coder.tag) if coder.tag
              coder.seq.each { |e| s.seq_add(visit(e)) }
              s
            else
              m = @tree.new_mapping
              m.set_tag(coder.tag) if coder.tag
              coder.each { |k, v| m.map_add(key_text(k), visit(v)) }
              m
            end
          remember(obj, node)
          node.set_anchor(name) if name
          node
        end

        def visit_object(obj)
          state, name = anchor_for(obj)
          return alias_of(obj, name) if state == :alias

          m = @tree.new_mapping
          remember(obj, m)
          m.set_anchor(name) if name
          m.set_tag("!ruby/object:#{obj.class.name}")
          obj.instance_variables.each do |ivar|
            m.map_add(ivar.to_s, visit(obj.instance_variable_get(ivar)))
          end
          m
        end

        def alias_of(obj, name)
          @tree.new_alias(@nodes.fetch(obj.object_id), name)
        end

        def remember(obj, node)
          (@nodes ||= {})[obj.object_id] = node
        end

        def key_text(k)
          k.is_a?(Symbol) ? ":#{k}" : k.to_s
        end

      end

      # Load side: revival of !ruby/... tags over the parsed Nodes
      # tree. The Materializer stays the plain-data fast path.
      class ToRuby
        def self.visit(node)
          new.visit(node)
        end

        def visit(node)
          @root ||= node
          case node
          when ::Yeptris::Psych::Nodes::Alias then visit_alias(node)
          when ::Yeptris::Psych::Nodes::Scalar then visit_scalar(node)
          when ::Yeptris::Psych::Nodes::Sequence then visit_sequence(node)
          when ::Yeptris::Psych::Nodes::Mapping then visit_mapping(node)
          else node&.to_ruby
          end
        end

        private

        def anchors
          @anchors ||= {}
        end

        def visit_alias(node)
          name = node.anchor
          unless anchors.key?(name)
            target = find_anchored(root_container(node), name)
            anchors[name] = target ? visit(target) : nil
          end
          anchors[name]
        end

        # the walk for alias targets starts at the first node this
        # visitor was handed (the document's root)
        def root_container(_node)
          @root
        end

        def find_anchored(node, name)
          return node if node.respond_to?(:anchor) && node.anchor == name

          node.children.each do |c|
            found = find_anchored(c, name)
            return found if found
          end
          nil
        end

        def visit_scalar(node)
          node.to_ruby
        end

        def visit_sequence(node)
          if node.tag == "!ruby/set"
            set = ::Set.new
            anchors[node.anchor] = set if node.anchor
            node.children.each { |c| set << visit(c) }
            return set
          end
          ary = []
          anchors[node.anchor] = ary if node.anchor
          node.children.each { |c| ary << visit(c) }
          ary
        end

        def visit_mapping(node)
          tag = node.tag
          return hash_into({}, node) if tag.nil? || tag.empty?

          case tag
          when "!ruby/set"
            set = Set.new
            anchors[node.anchor] = set if node.anchor
            node.children.each_slice(2) { |_k, v| set << visit(v) }
            set
          when /\A!ruby\/struct(?::(.+))?\z/
            klass = resolve_class(Regexp.last_match(1).to_s)
            pairs = {}
            anchors[node.anchor] = nil # placeholder: filled below
            node.children.each_slice(2) do |k, v|
              pairs[visit(k).to_s.sub(/\A:/, "")] = visit(v)
            end
            keys = pairs.keys.map(&:to_sym)
            built =
              if klass && klass <= Struct
                klass.new(*pairs.values)
              else
                Struct.new(*keys).new(*pairs.values)
              end
            anchors[node.anchor] = built if node.anchor
            built
          when /\A!ruby\/object(?::(.+))?\z/
            klass = resolve_class(Regexp.last_match(1).to_s)
            revive_object(klass, node)
          else
            hash_into({}, node)
          end
        end

        def hash_into(h, node)
          anchors[node.anchor] = h if node.anchor
          node.children.each_slice(2) do |k, v|
            h[visit(k)] = visit(v)
          end
          h
        end

        def revive_object(klass, node)
          obj = klass ? klass.allocate : ::Object.new
          anchors[node.anchor] = obj if node.anchor
          node.children.each_slice(2) do |k, v|
            key = k.to_ruby.to_s
            if key == "__init__"
              init_with(obj, v)
            else
              ivar = key.start_with?("@") ? key.to_sym : "@#{key}".to_sym
              obj.instance_variable_set(ivar, visit(v))
            end
          end
          obj
        end

        def init_with(obj, value_node)
          return unless obj.respond_to?(:init_with)

          coder = ::Yeptris::Psych::CoderShim.new
          if value_node.is_a?(::Yeptris::Psych::Nodes::Mapping)
            value_node.children.each_slice(2) do |k, v|
              coder[k.to_ruby.to_s] = visit(v)
            end
          end
          obj.init_with(coder)
        end

        def resolve_class(name)
          return nil if name.nil? || name.empty?

          klass = ::Object.const_get(name)
          raise DisallowedClass, name unless klass.is_a?(Class) || klass.is_a?(Module)

          klass
        rescue ::NameError
          nil
        end
      end
    end
  end
end
