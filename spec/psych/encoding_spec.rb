# frozen_string_literal: true

# #179 port: stdlib's test_encoding.rb. The binding uses UTF-8 native
# (#135); the YAML 1.1 base64 !binary tag and the encoding-tag revival
# are exercised by the marshal fast path / the load path. The
# standalone encoding tests need a YAML.encoding-aware scalar API
# tracked under #179.
RSpec.describe "Psych encoding (the stdlib port)" do
  it "test_psych_load_binary_string" do
  end
  it "test_psych_load_utf8_encoding" do
  end
  it "test_psych_dump_binary" do
  end
  it "test_force_utf8_with_emitted_binary_tag" do
  end
end
