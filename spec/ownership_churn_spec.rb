# frozen_string_literal: true

require "spec_helper"
require "stringio"

# #182: the abort class under document churn. A tree-side finalizer
# whose proc closed over the document wrapper raced that wrapper's
# own sweep — freed?/free against half-collected ivars, then a garbage
# C pointer into yeptris_document_free → SIGABRT. Position varied with
# GC timing (single examples passed; the cumulative run died).
#
# The ownership flip: the Document wrapper is the SOLE owner (its
# finalizer captures ONLY the raw pointer); trees REFERENCE it, never
# free it; Document#free undefines its finalizer BEFORE the C free.
#
# The old shape has a DETERMINISTIC tell: Ruby warns "finalizer
# references object to be finalized" on every churn run with a racy
# tree-side closure, and the sole-owner model emits none. That warning
# is asserted, so the gate no longer depends on the intermittent abort.
# Collections are forced at the lifecycle boundaries rather than after
# every allocation: the GC.stress-every-allocation window spent 77
# minutes per CI leg (99.9% of the whole suite) re-collecting Psych's
# allocation storm. A stress slice is kept for ordering coverage.
RSpec.describe "document ownership under churn (#182)" do
  before(:all) { require "yeptris/psych/drop_in" }

  DOC = "- id: 1\n  title: T\n  link:\n  - content: x\n    type: BIP\n".freeze
  INDEX = (1..500).map { |i| "- :id: #{i}\n  :file: d#{i}.yaml\n" }.join.freeze
  CYCLES = 80
  STRESS_EVERY = 16
  TELL = "finalizer references object to be finalized"

  it "survives cumulative churn and emits no racy-finalizer tell" do
    cap = StringIO.new
    saved_stderr = $stderr
    $stderr = cap
    begin
      CYCLES.times do |i|
        tree = ::Psych.parse(DOC)
        tree.children.first.to_ruby
        ::Psych.parse_stream(DOC) { |d| d.to_ruby }
        ::Psych.unsafe_load(INDEX)

        if (i % STRESS_EVERY).zero?
          # Keep a slice of the class the original tripwire proved: a
          # collection after every allocation across the full lifecycle.
          ::GC.stress = true
          begin
            d = ::Yeptris::Document.parse(DOC, schema: :compat_11)
            d.root.to_ruby
            d.free
          ensure
            ::GC.stress = false
          end
        else
          # Collect at the finalizer-window boundaries: wrapper built,
          # tree built, explicit free performed.
          d = ::Yeptris::Document.parse(DOC, schema: :compat_11)
          ::GC.start
          d.root.to_ruby
          ::GC.start
          d.free
          ::GC.start
        end
      end
      ::GC.start
    ensure
      ::GC.stress = false
      $stderr = saved_stderr
    end

    expect(cap.string).not_to include(TELL)
  end

  it "Document#free is idempotent and stops the finalizer" do
    d = ::Yeptris::Document.parse(DOC, schema: :compat_11)
    expect(d.freed?).to be(false)
    d.free
    expect(d.freed?).to be(true)
    expect { d.free }.not_to raise_error # second free is a no-op
    ::GC.start # the undefine'd finalizer must not fire
  end
end
