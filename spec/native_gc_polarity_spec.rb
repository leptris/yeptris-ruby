# frozen_string_literal: true

# yeptris-ruby#259: the native CBOR loader's GC guard tested the
# inverted sense of rb_gc_disable's return, so every CBOR decode —
# including Init_native's own self-check at require time — left GC
# permanently disabled for the process. Symptom: linear native RSS
# growth on every dump/load (nothing was ever swept), finalizers
# that never ran, and GC.start that could not reduce anything.
#
# These pins hold the polarity on every path that toggles GC, on
# every Ruby that loads the precompiled materializer.

def gc_was_disabled?
  # GC.disable returns true only when GC was ALREADY disabled; restore
  # immediately so the probe never changes the state it measures.
  was = GC.disable
  GC.enable unless was
  was
end

RSpec.describe "native materializer GC polarity (#259)" do
  NATIVE = defined?(::Yeptris::Native) && ::Yeptris::Native.const_defined?(:AVAILABLE)

  before do
    skip "the native materializer is not loaded (FFI ladder carries this run)" unless NATIVE
  end

  it "leaves GC enabled after require (the Init self-check rides the CBOR path)" do
    expect(gc_was_disabled?).to be(false)
  end

  it "leaves GC enabled after a CBOR decode" do
    ::Yeptris::CBOR.load("\xA1\x61\x6B\x01") # {"k" => 1}
    expect(gc_was_disabled?).to be(false)
  end

  it "leaves GC enabled after a CBOR decode failure" do
    expect { ::Yeptris::CBOR.load("\xFF\xFF") }.to raise_error(Yeptris::Error)
    expect(gc_was_disabled?).to be(false)
  end

  it "leaves GC enabled after a JSON load" do
    ::Yeptris::JSON.load('{"a": [1, 2.5, "x", true, null]}')
    expect(gc_was_disabled?).to be(false)
  end

  it "leaves GC enabled after a JSON parse failure" do
    expect { ::Yeptris::JSON.load("{oops") }.to raise_error(Yeptris::JSON::ParseError)
    expect(gc_was_disabled?).to be(false)
  end

  it "leaves GC enabled after Native.load" do
    ::Yeptris::Native.load("a: [1, 2]\n", nil)
    expect(gc_was_disabled?).to be(false)
  end

  it "leaves GC enabled when a caller had GC disabled across a call" do
    was = GC.disable
    begin
      ::Yeptris::CBOR.load("\xA1\x61\x6B\x01")
      expect(gc_was_disabled?).to be(true) # a pre-disabled GC stays disabled
    ensure
      GC.enable unless was
    end
  end
end
