# frozen_string_literal: true

require "date"
require "time"
require "set"

module Yeptris
  module Psych
    module Visitors
      # The dump-side visitor (Psych's YAMLTree core): an arbitrary
      # Ruby object graph becomes DOM nodes — anchors for shared
      # objects, aliases for repeats, the Encodable protocol, and the
      # !ruby/... tags Psych's own emitter produces.
      class YAMLTree
        # The chevron KEY tag the bulk lane stores: the full core URI
        # the engine's tag writer renders as !!str (the verbatim
        # shorthand would emit as a LOCAL tag — writer.c's regression).
        # One definition, in the writer of the tag bytes (BulkBuilder).
        MERGE_KEY_TAG = ::Yeptris::YAML::BulkBuilder::MERGE_KEY_TAG

        # stdlib's factory (relaton's db cache calls it): the options
        # reach the engine's emitter — :line_width and :canonical ride
        # yeptris_emit_options (13B), :indentation is accepted for
        # Psych parity (the engine's YAML emitter carries no
        # indentation knob; emit.h's struct is size/canonical/
        # best_width/explicit_doc_start).
        def self.create(options = {}, emitter = nil)
          new(options: options)
        end

        # force_node: the node walk's escape hatch — the A/B switch the
        # byte-parity specs drive (#857). Hosts never pass it; stdlib's
        # .create(options, emitter) signature is untouched.
        def initialize(schema: nil, options: {}, force_node: false)
          @options = options || {}
          @tree = ::Yeptris::Document.create(schema: schema)
          @names = {}  # object_id -> anchor name
          @counter = 0
          @bulk_ok = ::Yeptris::FFI::BULK_BUILD && !force_node
          @force_node = force_node
        end

        def push(obj)
          @refs = Hash.new(0)
          @refs[obj.object_id] += 1 # the root counts as a reference
          # re-armed per push: the gate walk below clears it for any
          # graph the bulk lane cannot express
          @fast = @bulk_ok && !@force_node
          count_refs(obj, {})
          if @fast
            build_bulk(obj) # the node-free lane (#857): one FFI call, no handles
            return self
          end
          root = visit(obj)
          @tree.set_root(root) if root
          self
        end
        alias_method :<<, :push # stdlib's dump body pushes via <<

        # Whether push took the node-free lane. False when the graph
        # carries anchor candidates, tagged/object shapes, or the
        # engine predates the bulk build (the capability probe).
        def fast_lane?
          @took_fast == true
        end

        # stdlib Psych.dump's tail: `visitor.tree.yaml io, options` —
        # the tree wraps the built document; yaml serializes it
        # (string return, or writes + returns the io)
        def tree
          BuiltDocument.new(@tree)
        end

        # The raw document (the CBOR encoder consumes the tree
        # directly; #tree wraps it for stdlib's yaml face)
        def document
          @tree
        end

        def finish
          @tree.serialize(canonical: @options[:canonical] ? true : false,
                          best_width: @options[:line_width] || 0,
                          explicit_doc_start: true)
        end

        # The built-document handle stdlib's dump tail serializes
        class BuiltDocument
          def initialize(doc)
            @doc = doc
          end

          def yaml(io = nil, options = {})
            options ||= {}
            out = @doc.serialize(canonical: options[:canonical] ? true : false,
                                 best_width: options[:line_width] || 0,
                                 explicit_doc_start: true)
            return out unless io

            io.write(out)
            io
          end
        end

        # stdlib register()s every object — scalars included — so a
        # repeated scalar dumps &name/*name (test_float_references,
        # test_alias_with_time). Containers already route through
        # anchor_for; this is the scalar arm of the same machinery.
        def anchored_scalar(obj, text: nil, tag: nil)
          state, name = anchor_for(obj)
          return alias_of(obj, name) if state == :alias

          n = scalar(text || obj, tag: tag)
          n.set_anchor(name) if name
          remember(obj, n)
          n
        end

        def visit(obj)
          case obj
          # strings/floats/ints: stdlib yaml_tree does NOT anchor them
          # (its float test is load-side only) — and CBOR encode
          # rejects the anchors the cbor profile feeds it
          when nil, true, false, ::Integer, ::Float, ::String then scalar(obj)
          when ::Symbol then @tree.new_scalar(":#{obj}", :plain) # psych emits symbols bare, never through visit_String's quoting rules
          # stdlib visit_DateTime: the class tag carries the type (a
          # plain timestamp re-loads as Time) — "!ruby/object:DateTime
          # 2017-04-13 12:00:00.500000000 +09:00", to_s text, one line
          when ::DateTime
            anchored_scalar(obj, text: obj.strftime("%F %H:%M:%S.%9N %:z"),
                            tag: "!ruby/object:DateTime")
          when ::Date, ::Time then anchored_scalar(obj) # timestamp text, never ivars
          when ::Hash then visit_hash(obj)
          when ::Array then visit_array(obj)
          when ::Struct then visit_struct(obj)
          when ::Set then visit_set(obj)
          when Encodable then visit_encode_with(obj)
          else
            if obj.instance_of?(::Object)
              # A BARE Object has no declared state to lose — the
              # empty !ruby/object form is correct by construction
              # (an Object with ivars set from outside its class is
              # outside the encapsulation contract; use a real class
              # with Encodable for stateful objects).
              return visit_bare_object(obj)
            end
            refuse_dump(obj)
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
          name = (@counter += 1).to_s # stdlib: &1, *1
          @names[oid] = name
          [:new, name]
        end

        # The reference-count walk doubles as the node-free lane's
        # gate (#857): the graph rides the bulk build only when every
        # value is a plain-data type AND no anchorable object repeats
        # (anchors/aliases are inexpressible in the flat entry stream).
        def count_refs(obj, seen)
          return if seen.key?(obj.object_id)

          seen[obj.object_id] = true
          case obj
          when Hash
            obj.each_value { |v| bump_ref(v); count_refs(v, seen) }
          when Array
            obj.each { |v| bump_ref(v); count_refs(v, seen) }
          when Struct
            @fast = false # !ruby/struct tag
            obj.each_pair { |_k, v| @refs[v.object_id] += 1; count_refs(v, seen) }
          when Set
            @fast = false # !ruby/set tag
            obj.each { |v| @refs[v.object_id] += 1; count_refs(v, seen) }
          when ::String, ::Integer, ::Float, ::Symbol, ::Date, ::Time, true, false, nil
            # bulk-lane immutables — except DateTime, which carries the
            # !ruby/object:DateTime tag even when unshared (the visit
            # dispatch's own DateTime arm)
            @fast = false if obj.is_a?(::DateTime)
          when ::Numeric
            # BigDecimal & co: visit's refuse_dump owns the contract
            # (and its message) — the node walk keeps it
            @fast = false
          else
            unless obj.instance_of?(::Object)
              refuse_dump(obj) unless obj.is_a?(Encodable)
              # Encodable: descend through the PUBLIC protocol so
              # shared objects inside coder contents still get
              # anchors — encode_with must be pure (it runs once more
              # at dump).
              coder = ::Yeptris::Psych::CoderShim.new(nil)
              obj.encode_with(coder)
              case coder.type
              when :seq
                coder.seq.each { |v| @refs[v.object_id] += 1; count_refs(v, seen) }
              when :map
                coder.each { |_k, v| @refs[v.object_id] += 1; count_refs(v, seen) }
              end
            end
            @fast = false # bare Object and Encodable: the node walk owns them
          end
        end

        # A SECOND occurrence forces the node walk when the object's
        # visit arm anchors (Hash/Array and the timestamp family —
        # anchored_scalar). Plain scalars never anchor (the stdlib
        # law), so shared strings, numbers, bools and nils stay on the
        # bulk lane.
        def bump_ref(v)
          @refs[v.object_id] += 1
          return unless @refs[v.object_id] == 2

          @fast = false unless v.is_a?(::String) || v.is_a?(::Symbol) ||
                               v.is_a?(::Integer) || v.is_a?(::Float) ||
                               v.equal?(true) || v.equal?(false) || v.nil?
        end

        def build_bulk(obj)
          # The node-free lane (#857): the SAME flat entry stream the
          # neutral face's BulkBuilder feeds yeptris_document_build —
          # one FFI call raises the document, zero node handles, zero
          # anchor bookkeeping (a graph that needed any would have
          # taken the node walk above). Merge keys carry the FULL core
          # URI: the engine's tag writer spells !!str from it (the
          # verbatim shorthand would emit as a LOCAL tag — the
          # writer.c chevron-key regression).
          ::Yeptris::YAML::BulkBuilder.build_into(@tree, obj, MERGE_KEY_TAG)
          @took_fast = true
        end

        def refuse_dump(obj)
          raise ::Yeptris::DumpError,
                "cannot dump #{obj.class}: include Yeptris::Psych::Encodable and implement encode_with(coder)"
        end

        def scalar(obj, tag: nil)
          # strings route through the builder's plain-safety helper
          # (one quoting rule, DRY); other scalars are their own text
          text =
            if obj.is_a?(::Time)
              # psych-5's format_time (#300 family 1) — the FIRST cut
              # put this branch after the Date||Time iso8601 one, dead
              # code: Psych.dump of a Hash still emitted iso8601 (the
              # neutral surface alone was pinned)
              ::Yeptris::YAML::BulkBuilder.time_text(obj)
            elsif obj.is_a?(::Date)
              obj.iso8601 # canonical calendar form
            elsif obj.nil?
              "" # libyaml's null rendering rides bare (issue #290)
            elsif obj.is_a?(::Float)
              ::Yeptris::YAML::BulkBuilder.float_text(obj)
            else
              obj.to_s
            end
          n =
            if obj.is_a?(::String) && !tag
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
          hash.each do |k, v|
            if k.nil?
              # Psych's nil-key form: `! ''` — the explicit tag on an
              # empty single-quoted key (#300 family 2)
              key_node = @tree.new_scalar("", :single_quoted)
              key_node.set_tag("!")
              m.map_add_node(key_node, visit(v))
            elsif k.is_a?(::String) && k == "<<"
              # stdlib yaml_tree: a literal chevron key carries the
              # explicit !!str tag (single-quoted) so it does not
              # re-load as a merge
              key_node = @tree.new_scalar("<<", :single_quoted)
              key_node.set_tag("tag:yaml.org,2002:str")
              m.map_add_node(key_node, visit(v))
            else
              # String keys ride psych's ONE visit_String law (the
              # reshape words quote in key position too: "n": 1,
              # 'yes': ... — #1264's premise had the psych side
              # inverted; stdlib quotes these keys on every version
              # since 4.0.2). Symbols stay :sym text (never through
              # visit_String), matching stdlib.
              key_node =
                if k.is_a?(::String)
                  ::Yeptris::YAML::Builder.build_string(@tree, k)
                else
                  @tree.new_scalar(key_text(k), :plain)
                end
              m.map_add_node(key_node, visit(v))
            end
          end
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
          m.set_tag(strct.class.name.to_s.empty? ? "!ruby/struct" : "!ruby/struct:#{strct.class.name}")
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
          obj.encode_with(coder) # the typed public surface
          # Wrap coder contents in a __init__ sub-mapping so the load
          # side can dispatch back into obj.init_with(coder) without
          # library-side ivar reflection (the encapsulation law).
          init = @tree.new_mapping
          case coder.type
          when :scalar
            init.map_add("__scalar__", scalar(coder.scalar))
            init.map_add("__tag__", scalar(coder.tag)) if coder.tag
          when :seq
            inner = @tree.new_sequence
            inner.set_tag(coder.tag) if coder.tag
            coder.seq.each { |e| inner.seq_add(visit(e)) }
            init.seq_add(inner)
          else
            coder.each { |k, v| init.map_add(key_text(k), visit(v)) }
            init.set_tag(coder.tag) if coder.tag
          end
          m = @tree.new_mapping
          m.set_anchor(name) if name
          custom = ::Yeptris::Psych.dump_tags[obj.class]
          m.set_tag(custom || "!ruby/object:#{obj.class.name}")
          m.map_add("__init__", init)
          remember(obj, m)
          m
        end

        def visit_bare_object(obj)
          state, name = anchor_for(obj)
          return alias_of(obj, name) if state == :alias

          m = @tree.new_mapping
          remember(obj, m)
          m.set_anchor(name) if name
          m.set_tag("!ruby/object")
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

        # stdlib ToRuby#accept's domain post-pass: normalize the tag
        # (strip leading !//, ensure tag: unless x-private) and run the
        # registered block over the revived result (#95 thread)
        def apply_domain_type(result, node)
          return result if node.tag.nil? || node.tag.empty?

          key = node.tag.sub(/\A[!\/]*/, "").sub(/(,\d+)\//, '\1:')
          key = "tag:#{key}" unless key.match?(/\A(?:tag:|x-private)/)
          entry = ::Yeptris::Psych.domain_types[key]
          return result unless entry

          _value, block = entry
          block.call(key, result)
        end

        def visit(node)
          @root ||= node
          result =
            case node
            when ::Yeptris::Psych::Nodes::Alias then visit_alias(node)
            when ::Yeptris::Psych::Nodes::Scalar then visit_scalar(node)
            when ::Yeptris::Psych::Nodes::Sequence then visit_sequence(node)
            when ::Yeptris::Psych::Nodes::Mapping then visit_mapping(node)
            else node&.to_ruby
            end
          # stdlib register(): an anchored node's result is THE object
          # for every alias to that anchor (scalars included)
          anchors[node.anchor] = result if node.respond_to?(:anchor) && node.anchor
          # the domain-types post-pass (stdlib ToRuby#accept's tail):
          # registered blocks transform the revived result per node
          if node && !::Yeptris::Psych.domain_types.empty?
            result = apply_domain_type(result, node)
          end
          result
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
          return node if node.anchor == name

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
          when /\A!ruby\/hash:(.+)\z/
            revive_hash_class(resolve_class(Regexp.last_match(1)), node)
          when /\A!ruby\/exception(?::(.*))?\z/
            revive_exception(resolve_class(Regexp.last_match(1).to_s), node)
          else
            # Psych.load_tags first (the class registry, #95 bug 4);
            # anything else stays the plain mapping
            if (klass = ::Yeptris::Psych.load_tags[tag])
              revive_tagged(klass, node)
            else
              hash_into({}, node)
            end
          end
        end

        # stdlib visit_hash's merge branch, verbatim in structure: the
        # key's SHAPE decides (an explicit !!str '<<' is a literal key,
        # not a merge), the VALUE's node kind picks the arm, and every
        # merge is TypeError-guarded (a bad element keeps the whole
        # '<<' pair literal — merges are all-or-nothing). The anchor
        # registrant is the receiver by default; the object revivals
        # pass the revived OBJ (psych's revive(): the object itself is
        # registered before the children walk, so an alias inside an
        # ivar pointing back at the object resolves to it).
        def hash_into(h, node, anchor: nil)
          anchors[node.anchor] = (anchor || h) if node.anchor
          node.children.each_slice(2) do |k, v|
            key = visit(k)
            val = visit(v)
            if key == "<<" && k.tag != "tag:yaml.org,2002:str"
              case v
              when ::Yeptris::Psych::Nodes::Alias, ::Yeptris::Psych::Nodes::Mapping
                begin
                  h.merge!(val)
                rescue ::TypeError
                  h[key] = val
                end
              when ::Yeptris::Psych::Nodes::Sequence
                begin
                  merged = {}
                  val.reverse_each { |value| merged.merge!(value) }
                  h.merge!(merged)
                rescue ::TypeError
                  h[key] = val
                end
              else
                h[key] = val
              end
            else
              h[key] = val
            end
          end
          h
        end

        # A load_tags-registered class revives from the mapping's own
        # top-level pairs (Psych's coder semantics — no __init__
        # wrapper, which is OUR encoder's internal convention)
        def revive_tagged(klass, node)
          raise ::Yeptris::DumpError,
                "#{klass} is not Yeptris::Psych::Encodable: implement init_with(coder)" unless klass <= ::Yeptris::Psych::Encodable

          obj = klass.allocate
          anchors[node.anchor] = obj if node.anchor
          coder = ::Yeptris::Psych::CoderShim.new
          node.children.each_slice(2) do |k, v|
            coder[k.to_ruby.to_s] = visit(v)
          end
          obj.init_with(coder)
          obj
        end

        def revive_object(klass, node)
          obj = klass ? klass.allocate : ::Object.allocate
          # psych's revive(): the object registers BEFORE the children
          # walk — an alias inside the state pointing back at the
          # object resolves to it (identity through ivars)
          anchors[node.anchor] = obj if node.anchor

          if klass
            # The yeptris encoder's format (visit_encode_with): the
            # Encodable protocol rides the __init__ marker, so the
            # state passes back through init_with(coder) without
            # library-side ivar reflection. The format decides on the
            # RAW key before any value is visited (the old walk's
            # shape; sibling values stay untouched when it fires).
            init = nil
            node.children.each_slice(2) do |k, v|
              init = v if k.to_ruby.to_s == "__init__"
            end
            if init
              unless klass <= ::Yeptris::Psych::Encodable
                raise ::Yeptris::DumpError,
                      "#{klass} is not Yeptris::Psych::Encodable: implement init_with(coder)"
              end

              coder = ::Yeptris::Psych::CoderShim.new
              if init.is_a?(::Yeptris::Psych::Nodes::Mapping)
                init.children.each_slice(2) do |ck, cv|
                  coder[ck.to_ruby.to_s] = visit(cv)
                end
              end
              obj.init_with(coder)
              return obj
            end
          end

          # stdlib psych's format (visit_Object + dump_ivars): the
          # mapping's own top-level pairs ARE the object state —
          # revives through init_with when the class defines it, ivar
          # assignment otherwise. THE AUDIT FIX: the __init__-only
          # walk silently dropped the ivars of every stdlib
          # Psych.dump-produced document.
          init_with_state(obj, hash_into({}, node, anchor: obj), node)
          obj
        end

        # !ruby/hash:K (stdlib visit_Hash of a Hash subclass): the
        # SUBCLASS allocates and the mapping's own pairs fill it
        # (merge keys included, hash_into semantics). A name that
        # resolves to a non-Hash raises stdlib resolve_subclass's
        # ArgumentError; an unresolvable name stays a plain Hash (the
        # resolve_class-returns-nil convention this binding already
        # applies to !ruby/object and !ruby/struct — safe_load raises
        # DisallowedClass for it first).
        def revive_hash_class(klass, node)
          if klass
            unless klass <= ::Hash
              raise ::ArgumentError, "Invalid tag: expected a subclass of Hash, got #{klass}"
            end

            h = klass.allocate
          else
            h = {}
          end
          anchors[node.anchor] = h if node.anchor
          hash_into(h, node)
          h
        end

        # !ruby/exception[:K] (stdlib visit_Exception + build_exception):
        # the message rides the exception's own construction surface
        # (Class#exception — psych's C build_exception writes the
        # engine-internal mesg slot on an allocated instance, which
        # Ruby-level ivar assignment cannot reach: message would stay
        # the class name), backtrace is consumed if present, and every
        # other pair lands as ivars (message/backtrace excepted — they
        # name the exception's own surface, not object state). Bare
        # !ruby/exception rides ::Exception (psych's class_loader
        # exception fallback). A subclass whose initialize refuses a
        # message argument constructs bare — same fallback psych's
        # Ruby-side build_exception carried before the C move.
        def revive_exception(klass, node)
          h = {}
          node.children.each_slice(2) do |k, v|
            h[visit(k)] = visit(v)
          end
          mesg = h.delete("message")
          e = build_exception(klass || ::Exception, mesg)
          anchors[node.anchor] = e if node.anchor
          e.set_backtrace(h.delete("backtrace")) if h.key?("backtrace")
          init_with_state(e, h, node)
          e
        end

        def build_exception(klass, mesg)
          return klass.exception if mesg.nil?

          begin
            klass.exception(mesg)
          rescue ::ArgumentError, ::TypeError
            klass.exception
          end
        end

        # psych's init_with: a class defining init_with takes the coder
        # (the raw pair map, coder.tag = the mapping's tag); everything
        # else — bare Object included — takes the pairs as ivars. Keys
        # are @-normalized both ways: stdlib DUMPS the ivars @-stripped
        # (yaml_tree's dump_ivars), older psych and hand-written docs
        # spell them WITH the @ — both map to the same ivar.
        def init_with_state(obj, h, node)
          if obj.respond_to?(:init_with)
            coder = ::Yeptris::Psych::CoderShim.new
            coder.tag = node.tag
            h.each { |k, v| coder[k] = v }
            obj.init_with(coder)
          else
            h.each do |k, v|
              obj.instance_variable_set(:"@#{k.to_s.sub(/\A@/, "")}", v)
            end
          end
          obj
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
