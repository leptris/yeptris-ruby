# frozen_string_literal: true

module Yeptris
  module Psych
    # The event-level API (TODO.impl/15 phase E): the abstract base
    # Psych::Parser dispatches onto. Every event a YAML stream can
    # produce is a method; the arg shapes are Psych's own (verified
    # differentially against the stdlib recorder in the specs).
    class Handler
      # Scalar styles — the same integers Psych::Nodes::Scalar uses,
      # and the same values YeptrisEventRecord.style carries.
      ANY = 0
      PLAIN = 1
      SINGLE_QUOTED = 2
      DOUBLE_QUOTED = 3
      LITERAL = 4
      FOLDED = 5

      # Collection styles (Psych::Nodes::Sequence / Mapping).
      BLOCK = 1
      FLOW = 2

      class DumperOptions
        attr_accessor :line_width, :indentation, :canonical

        def initialize
          @line_width = 0
          @indentation = 2
          @canonical = false
        end
      end

      OPTIONS = DumperOptions.new

      EVENTS = %i[alias empty end_document end_mapping end_sequence end_stream
                  scalar start_document start_mapping start_sequence start_stream].freeze

      # Called once per stream; +encoding+ is a Psych::Parser
      # encoding constant (we always parse to UTF-8).
      def start_stream(encoding); end

      # +version+ is [major, minor] when %YAML declared, else nil
      # (yeptris does not carry the directive into the event).
      # +tag_directives+ is a list of [handle, prefix] pairs ([] for
      # us: same directive omission). +implicit+ true without ---.
      def start_document(version, tag_directives, implicit); end

      def end_document(implicit); end

      def alias(anchor); end

      # +style+ is one of the scalar constants above; +plain+ /
      # +quoted+ are the implicit-typing flags (plain: resolvable
      # without a tag).
      def scalar(value, anchor, tag, plain, quoted, style); end

      def start_sequence(anchor, tag, implicit, style); end

      def end_sequence; end

      def start_mapping(anchor, tag, implicit, style); end

      def end_mapping; end

      def end_stream; end

      # libyaml artifact (its NO_EVENT after stream end); the
      # yeptris engine never produces one, so this never fires.
      def empty; end
    end

    module Handlers
      # Captures every event as [name, args] — Psych's own Recorder
      # shape, so recordings replay through any Handler-compatible
      # emitter.
      class Recorder < Handler
        attr_reader :events

        def initialize
          @events = []
          super()
        end

        Handler::EVENTS.each do |event|
          define_method(event) { |*args| @events << [event, args] }
        end
      end
    end
  end
end
