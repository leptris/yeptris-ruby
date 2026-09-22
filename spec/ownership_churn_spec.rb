# frozen_string_literal: true

require "spec_helper"

# #182: the abort class under document churn. A tree-side finalizer
# whose proc closed over the document wrapper raced that wrapper's
# own sweep — freed?/free against half-collected ivars, then a garbage
# C pointer into yeptris_document_free → SIGABRT. Position varied with
# GC timing (single examples passed; the cumulative run died).
#
# The ownership flip: the Document wrapper is the SOLE owner (its
# finalizer captures ONLY the raw pointer); trees REFERENCE it, never
# free it; Document#free undefines its finalizer BEFORE the C free.
# This stress test would have aborted under the old model.
RSpec.describe "document ownership under churn (#182)" do
  before(:all) { require "yeptris/psych/drop_in" }

  DOC = "- id: 1\n  title: T\n  link:\n  - content: x\n    type: BIP\n".freeze
  INDEX = (1..500).map { |i| "- :id: #{i}\n  :file: d#{i}.yaml\n" }.join.freeze

  # timeout: false - GC.stress multiplies wall time ~30x; on the shared
  # arm runner this example legitimately exceeds the 120s cap (#201)
  it "survives cumulative parse/stream/load/free under forced GC", timeout: false do
    # GC.stress forces a collection after every allocation — the
    # finalizer race window is maximized. A double free or a
    # use-after-free is a hard abort (trap 6 / SIGSEGV), not a
    # soft failure the expect can catch.
    ::GC.stress = true
    begin
      80.times do
        tree = ::Psych.parse(DOC)
        tree.children.first.to_ruby
        ::Psych.parse_stream(DOC) { |d| d.to_ruby }
        ::Psych.unsafe_load(INDEX)
        d = ::Yeptris::Document.parse(DOC, schema: :compat_11)
        d.root.to_ruby
        d.free # explicit free: undefine_finalizer + C free
      end
    ensure
      ::GC.stress = false
    end
    ::GC.start
    expect(true).to be(true) # survived = the assertion
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
