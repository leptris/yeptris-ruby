# frozen_string_literal: true

# #179 port: stdlib's test_encoding.rb. The binding uses UTF-8 native
# (#135); the YAML 1.1 base64 !binary tag and the encoding-tag revival
# are exercised by the marshal fast path / the load path. The
# standalone encoding tests need a YAML.encoding-aware scalar API
# tracked under #179.
RSpec.describe "Psych encoding (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  it "test_psych_load_binary_string" do
    binary = [0xC3, 0xA9].pack("C*").force_encoding(Encoding::UTF_8) # é
    loaded = ::Psych.load("--- #{binary}\n")
    expect(loaded.encoding).to eq(Encoding::UTF_8)
    expect(loaded).to eq(binary)
  end

  it "test_psych_load_utf8_encoding" do
    loaded = ::Psych.load("--- \u65e5\u672c\u8a9e\n")
    expect(loaded.encoding).to eq(Encoding::UTF_8)
  end

  it "test_psych_dump_binary" do
    blob = "\x00\xFF\xFE".b
    dumped = ::Psych.dump(blob)
    expect(dumped).to include("!binary")
    expect(::Psych.load(dumped)).to eq(blob)
  end

  it "test_force_utf8_with_emitted_binary_tag" do
    text = "\xC3\xA9 caf\xC3\xA9".dup.force_encoding(Encoding::UTF_8)
    dumped = ::Psych.dump(text)
    expect(::Psych.load(dumped).encoding).to eq(Encoding::UTF_8)
  end
end
