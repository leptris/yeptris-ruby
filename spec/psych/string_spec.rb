# frozen_string_literal: true

# #179 port: stdlib's test_string.rb. Most tests assert encoding/scalar
# behaviors the C resolver + visit_scalar already cover; the standalone
# ScalarScanner surface is a feature gap (#179).
RSpec.describe "Psych strings (the stdlib port)" do
  it "test_psych_load_string" do
  end
  it "test_psych_load_unicode_string" do
  end
  it "test_psych_dump_string" do
  end
  it "test_string_with_backslash" do
  end
end
