# frozen_string_literal: true

require "spec_helper"
require "yeptris"

# leptris/yeptris#863: on the x86_64-linux and Windows platform builds,
# fontist's suite saw plain string scalars under `key:` materialize as
# ONE-ELEMENT ARRAYS (the sha256 round-trips re-serialized as
# sequences) while arm64-darwin parsed the same document as a String.
# The C face pins the scalar kind arch-independently
# (leptris/yeptris test_parse.cpp PlainHexScalarStaysScalar863); this
# pins the binding's materialization the same way.
RSpec.describe "leptris/yeptris#863: plain scalar materialization" do
  let(:doc) do
    <<~YAML
      resources:
        andale32.exe:
          sha256: 0524fe42951adc3a7eb870e32f0920313c71f170c859b5f770d82b4ee111e970
    YAML
  end

  it "parses a plain hex scalar as a String, not a one-element Array" do
    h = Yeptris::YAML.load(doc)
    sha = h.dig("resources", "andale32.exe", "sha256")
    expect(sha).to be_a(String)
    expect(sha).to eq("0524fe42951adc3a7eb870e32f0920313c71f170c859b5f770d82b4ee111e970")
  end

  it "matches Psych on the same document" do
    require "psych"
    expect(Yeptris::YAML.load(doc)).to eq(Psych.parse(doc).to_ruby)
  end
end
