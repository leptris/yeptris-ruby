# frozen_string_literal: true

require "psych"
require "psych/handlers/recorder" # stdlib FIRST: the rebind keeps it as ORIGINAL
require "spec_helper"
require "yeptris/psych"

# The event-level API (TODO.impl/15 phase E): Psych::Parser +
# Psych::Handler + Psych::Handlers::Recorder. Arg shapes are Psych's
# own — verified differentially against the stdlib recorder.
RSpec.describe "Yeptris::Psych event API" do
  def yep_events(yaml)
    rec = ::Psych::Handlers::Recorder.new
    ::Psych::Parser.new(rec).parse(yaml)
    rec.events
  end

  describe "Handler base" do
    it "defines every event as a no-op" do
      h = ::Psych::Handler.new
      expect(h).to respond_to(*::Psych::Handler::EVENTS)
      expect { h.start_stream(1) }.not_to raise_error
      expect { h.start_document(nil, [], true) }.not_to raise_error
      expect { h.end_document(true) }.not_to raise_error
      expect { h.alias("a") }.not_to raise_error
      expect { h.scalar("v", nil, nil, true, false, 1) }.not_to raise_error
      expect { h.start_sequence(nil, nil, true, 1) }.not_to raise_error
      expect { h.end_sequence }.not_to raise_error
      expect { h.start_mapping(nil, nil, true, 1) }.not_to raise_error
      expect { h.end_mapping }.not_to raise_error
      expect { h.end_stream }.not_to raise_error
      expect { h.empty }.not_to raise_error
    end

    it "pins Psych's style constants" do
      expect(::Psych::Handler::PLAIN).to eq(1)
      expect(::Psych::Handler::SINGLE_QUOTED).to eq(2)
      expect(::Psych::Handler::DOUBLE_QUOTED).to eq(3)
      expect(::Psych::Handler::LITERAL).to eq(4)
      expect(::Psych::Handler::FOLDED).to eq(5)
      expect(::Psych::Handler::BLOCK).to eq(1)
      expect(::Psych::Handler::FLOW).to eq(2)
    end
  end

  describe "Parser" do
    it "defaults to a no-op handler and returns self" do
      parser = ::Psych::Parser.new
      expect(parser.handler).to be_a(::Psych::Handler)
      rec = ::Psych::Handlers::Recorder.new
      expect(::Psych::Parser.new(rec).parse("--- x")).to be_a(::Psych::Parser)
    end

    it "exposes the handler as an accessor" do
      rec = ::Psych::Handlers::Recorder.new
      parser = ::Psych::Parser.new
      parser.handler = rec
      parser.parse("--- x")
      expect(rec.events).not_to be_empty
    end

    it "records the filename" do
      parser = ::Psych::Parser.new(::Psych::Handlers::Recorder.new)
      parser.parse("--- x", "a.yml")
      expect(parser.filename).to eq("a.yml")
    end

    it "raises SyntaxError on bad input" do
      expect { yep_events("--- *undefined\n") }
        .to raise_error(::Psych::SyntaxError)
    end

    it "reads from an IO" do
      require "stringio"
      rec = ::Psych::Handlers::Recorder.new
      ::Psych::Parser.new(rec).parse(StringIO.new("--- 1\n"))
      expect(rec.events).to include([:scalar, ["1", nil, nil, true, false, 1]])
    end
  end

  describe "Recorder" do
    it "captures [name, args] pairs" do
      events = yep_events("- &x foo\n- *x\n")
      expect(events.first).to eq([:start_stream, [1]])
      expect(events.last).to eq([:end_stream, []])
      expect(events).to include([:scalar, ["foo", "x", nil, true, false, 1]])
      expect(events).to include([:alias, ["x"]])
    end
  end

  describe "event shapes (differential vs stdlib Psych)" do
    CASES = [
      "--- !!str foo\n",                       # resolved default tag
      "--- !str bar\n",                        # local tag verbatim
      "--- !<tag:e,2000:x> v\n",               # verbatim URI
      "--- &a [1, {x: 1}]\n",                  # anchored flow nesting
      "--- |\n  lit\n",                        # literal block
      "--- |-\n  strip\n",                     # literal chomp
      "--- >-\n  folded\n  text\n",            # folded block
      "plain\ntext\n",                         # implicit doc, folded plain
      "- &x foo\n- *x\n",                      # anchor + alias in seq
      "%YAML 1.1\n--- foo\n",                  # directive (version nil in events)
      "--- \"quoted\"\n",                      # double quoted implicit typing
      "--- 'single'\n",                        # single quoted implicit typing
      "a: 1\nb: {c: [2]}\n",                   # block map/seq + flow
      "---\n--- foo\n...\n",                   # empty doc + explicit end
      "--- !!seq [!!str x]\n",                 # tagged collections
      "? [k]\n: v\n",                          # explicit complex key
      "--- \n  multi\n  line\n",               # indented plain scalar
      "many:\n  - a\n  - |\n    b\n",          # literal inside a sequence
      "--- 'quo''ted'\n",                      # single-quote escape
      "--- \"a\\\"b\\\\c\"\n",                   # double-quote escapes
      "--- &anchor\na: 1\n",                   # anchored root mapping
      "---\n- - deep\n",                       # nested block sequences
      "# leading comment\n--- x # trailing\n", # comments
      "--- !!binary |\n  aGVsbG8=\n",          # binary tag
      "--- 2001-12-14 21:59:43.10 -05:00\n",   # timestamp (still a scalar)
      "a:\n  b:\n    c: d\n",                  # deep block mapping
      "--- [{a: 1}, [2, [3]]]\n",              # deep flow nesting
      "---\nx: &v\n- 1\n- *v\n",               # self-referencing via alias
      "--- ~\n",                               # null word
      "---\n",                                 # bare explicit document
    ].freeze

    # The one documented divergence: %YAML's [major, minor] is not
    # carried by the event record — stdlib reports [1, 1], we []
    # (directive-less documents match exactly: both pass []).
    VERSION_CASE = "%YAML 1.1\n--- foo\n"

    (CASES - [VERSION_CASE]).each_with_index do |yaml, i|
      it "case #{i} #{yaml.inspect}" do
        std = ::Psych::ORIGINAL::Handlers::Recorder.new
        ::Psych::ORIGINAL::Parser.new(std).parse(yaml)
        ours = ::Psych::Handlers::Recorder.new
        ::Psych::Parser.new(ours).parse(yaml)
        expect(ours.events).to eq(std.events)
      end
    end

    it "pins the %YAML version divergence" do
      std = ::Psych::ORIGINAL::Handlers::Recorder.new
      ::Psych::ORIGINAL::Parser.new(std).parse(VERSION_CASE)
      ours = ::Psych::Handlers::Recorder.new
      ::Psych::Parser.new(ours).parse(VERSION_CASE)
      expect(std.events[1]).to eq([:start_document, [[1, 1], [], false]])
      expect(ours.events[1]).to eq([:start_document, [[], [], false]])
    end

    # libyaml keeps anchors alive across documents (its own
    # lenience; the spec says per-document — our engine agrees with
    # the spec, so cross-document aliases error here)
    it "rejects cross-document aliases (spec-strict; libyaml accepts)" do
      expect { yep_events("--- &a x\n--- *a\n") }
        .to raise_error(::Psych::SyntaxError)
    end
  end
end
