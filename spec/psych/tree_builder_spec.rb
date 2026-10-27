# frozen_string_literal: true

# #179 port: stdlib's test_tree_builder.rb. Every Node carries
# start_line/start_column/end_line/end_column — the engine stamps
# libyaml's marks (the C EventMarks gate pins them against stdlib
# psych); the parser surfaces them through Handler#event_location and
# stdlib's TreeBuilder applies them to nodes. The fixture is strict-
# compatible (stdlib's own 1.1-lenient fixture is a deliberate reject);
# the expectations below are psych-verified for it (marks_oracle).
RSpec.describe "Psych tree builder (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  # a METHOD, not a top-level constant: YAML_DOC is a load-order
  # collision hazard across spec files (schema_spec defines its own)
  def yaml_doc
    <<~YAML
      a: 1
      b:
        - foo
        - bar
      c: &x val
      d: *x
    YAML
  end

  def tree_of(doc = yaml_doc)
    parser = ::Psych::Parser.new(::Psych::TreeBuilder.new)
    parser.parse(doc)
    parser.handler.root
  end

  def assert_location(node, sl, sc, el, ec)
    expect([node.start_line, node.start_column, node.end_line, node.end_column])
      .to eq([sl, sc, el, ec])
  end

  it "test_stream: the stream spans the input" do
    t = tree_of
    expect(t).to be_a(::Psych::Nodes::Stream)
    assert_location t, 0, 0, 6, 0
  end

  it "test_documents: the document spans the input" do
    t = tree_of
    expect(t.children.length).to eq(1)
    assert_location t.children.first, 0, 0, 6, 0
  end

  it "test_mapping: the root mapping spans the document" do
    doc = tree_of.children.first
    map = doc.children.first
    expect(map).to be_a(::Psych::Nodes::Mapping)
    assert_location map, 0, 0, 6, 0
  end

  it "test_scalar: keys, values, and anchored scalars carry exact spans" do
    map = tree_of.children.first.children.first
    a_key, a_val = map.children[0..1]
    assert_location a_key, 0, 0, 0, 1
    assert_location a_val, 0, 3, 0, 4
    c_val = map.children[5] # c: &x val — the span includes the anchor
    assert_location c_val, 4, 3, 4, 9
  end

  it "test_sequence: zero-span start at the dash, entries located" do
    map = tree_of.children.first.children.first
    seq = map.children[3]
    expect(seq).to be_a(::Psych::Nodes::Sequence)
    # the node's end = its end event's marks (stdlib semantics), not
    # the start event's
    assert_location seq, 2, 2, 4, 0
    assert_location seq.children[0], 2, 4, 2, 7
    assert_location seq.children[1], 3, 4, 3, 7
  end

  it "test_alias: the alias spans its star and name" do
    map = tree_of.children.first.children.first
    alias_node = map.children[7]
    expect(alias_node).to be_a(::Psych::Nodes::Alias)
    assert_location alias_node, 5, 3, 5, 5
  end
end
