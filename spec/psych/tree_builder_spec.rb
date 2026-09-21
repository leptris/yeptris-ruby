# frozen_string_literal: true

# #179 port: stdlib's test_tree_builder.rb. Asserts start_line,
# start_column, end_line, end_column on every Node (Document,
# Mapping, Scalar, Sequence, Alias). The binding's Nodes wrappers do
# not carry event locations — a feature gap tracked under #179.
RSpec.describe "Psych tree builder (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  xit "test_stream / test_documents / test_sequence / test_scalar / test_mapping / test_alias (every node carries start/end line:col — #179 feature)"
end
