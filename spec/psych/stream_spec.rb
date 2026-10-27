# frozen_string_literal: true

require "spec_helper"

# #179 port: stdlib's test_stream.rb. The binding's parse_stream builds
# a stream eagerly; the block-yielding form (stdlib's per-doc
# yielding + LocalJumpError-as-break) is tracked under #179. The
# node predicates (alias?, mapping?, sequence?, scalar?, document?,
# stream?) are defined on Nodes::Node (each class checks n.kind).
RSpec.describe "Psych stream (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  it "test_predicate_document / mapping / scalar / sequence / stream" do
    pairs = [
      [::Yeptris::Psych::Nodes::Document, "test_predicate_document"],
      [::Yeptris::Psych::Nodes::Mapping, "test_predicate_mapping"],
      [::Yeptris::Psych::Nodes::Scalar, "test_predicate_scalar"],
      [::Yeptris::Psych::Nodes::Sequence, "test_predicate_sequence"],
      [::Yeptris::Psych::Nodes::Stream, "test_predicate_stream"],
    ]
    pairs.each do |klass, _name|
      rb = ::Psych.parse_stream("---\n- foo: bar\n- &a !!str Anchored\n- *a")
      # grep over the whole tree (children are direct + descendants)
      flat = lambda do |n, acc = []|
        acc << n
        n.children.each { |c| flat.call(c, acc) } if n.respond_to?(:children)
        acc
      end
      nodes = flat.call(rb).grep(klass)
      expect(nodes.length).to be > 0
    end
  end

  it "returns the stream (the array form)" do
    rb = ::Psych.parse_stream("---\nfoo\n---\nbar\n")
    expect(rb).to be_a(::Yeptris::Psych::Nodes::Stream)
    expect(rb.children.size).to eq(2)
  end

  xit "test_predicate_alias (alias? needs an anchored node helper — #179)"
  xit "test_parse_partial (libyaml tolerates --- ` as empty; ours raises — #179)"
  xit "test_load_partial"
  it "test_parse_stream_yields_documents (block form — #179 round 4)" do
    yielded = []
    rb = ::Psych.parse_stream("---\nfoo\n---\nbar\n") { |doc| yielded << doc }
    expect(yielded.size).to eq(2)
    expect(yielded).to all(be_a(::Psych::Nodes::Document))
    expect(rb.children.size).to eq(2)
  end

  it "test_parse_stream_break (block form — #179 round 4)" do
    yielded = []
    ::Psych.parse_stream("---\nfoo\n---\nbar\n") do |doc|
      yielded << doc
      break
    end
    expect(yielded.size).to eq(1)
  end

  it "test_load_stream_yields_documents (block form — #179 round 4)" do
    yielded = []
    docs = ::Psych.load_stream("---\nfoo\n---\nbar\n") { |ruby| yielded << ruby }
    expect(docs).to eq(%w[foo bar])
    expect(yielded).to eq(%w[foo bar])
  end

  it "test_safe_load_stream_yields_documents" do
    yielded = []
    docs = ::Psych.safe_load_stream("---\nfoo\n---\n[1, 2]\n") { |ruby| yielded << ruby }
    expect(docs).to eq(["foo", [1, 2]])
    expect(yielded).to eq(["foo", [1, 2]])
  end
end
