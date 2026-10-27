# frozen_string_literal: true

module Yeptris
  module Psych
    # The stdlib TreeBuilder port (#179): builds a Nodes tree carrying
    # start/end line:column on every node. The parser calls
    # event_location before each event (psych 5's exact contract);
    # stdlib's class is the reference — this port follows it
    # function-for-function over the binding's keyword-arg Nodes.
    class TreeBuilder < Handler
      attr_reader :root

      def initialize
        super
        @stack = []
        @last = nil
        @root = nil
        @start_line = nil
        @start_column = nil
        @end_line = nil
        @end_column = nil
      end

      def event_location(start_line, start_column, end_line, end_column)
        @start_line = start_line
        @start_column = start_column
        @end_line = end_line
        @end_column = end_column
      end

      %w[Sequence Mapping].each do |node|
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def start_#{node.downcase}(anchor, tag, implicit, style)
            n = Nodes::#{node}.new(anchor: anchor, tag: tag, style: style)
            set_start_location(n)
            @last.children << n
            push n
          end

          def end_#{node.downcase}
            n = pop
            set_end_location(n)
            n
          end
        RUBY
      end

      def start_document(version, tag_directives, implicit)
        n = Nodes::Document.new(version, tag_directives)
        set_start_location(n)
        @last.children << n
        push n
      end

      def end_document(_implicit = false)
        n = pop
        set_end_location(n)
        n
      end

      def start_stream(_encoding)
        n = Nodes::Stream.new
        set_start_location(n)
        @root = n
        push n
      end

      def end_stream
        n = pop
        set_end_location(n)
        n
      end

      def scalar(value, anchor, tag, plain, quoted, style)
        n = Nodes::Scalar.new(value, anchor: anchor, tag: tag,
                              plain: plain, quoted: quoted, style: style)
        set_location(n)
        @last.children << n
        n
      end

      def alias(anchor)
        n = Nodes::Alias.new(anchor)
        set_location(n)
        @last.children << n
        n
      end

      private

      def push(value)
        @stack.push(value)
        @last = value
      end

      def pop
        value = @stack.pop
        @last = @stack.last
        value
      end

      def set_location(n)
        n.start_line = @start_line
        n.start_column = @start_column
        n.end_line = @end_line
        n.end_column = @end_column
      end

      def set_start_location(n)
        set_location(n)
      end

      def set_end_location(n)
        n.end_line = @end_line
        n.end_column = @end_column
      end
    end
  end
end
