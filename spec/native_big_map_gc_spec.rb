# frozen_string_literal: true

# yeptris-ruby#279 — the native JSON materializer must keep every
# staged pair visible to the GC. The pairs staging buffer lives on
# the C stack (scanned); an earlier revision spilled to malloc'd
# memory for maps beyond 31 pairs, which the collector does NOT
# scan — mid-parse it could free the staged keys/values and recycle
# their slots, so bulk_insert inserted garbage (the field SIGSEGV
# whose fault address was document text). The fix bounds the bulk
# path at the stack buffer and rides rb_hash_aset beyond it; this
# pin holds large maps to exact value integrity under stress.

require "json"

RSpec.describe "native JSON materializer GC visibility (#279)" do
  it "holds a >31-pair map to exact integrity (the old heap-staging threshold)" do
    next unless defined?(::Yeptris::Native)

    json = "{" + (0...64).map { |i|
      "\"key-#{i}\":\"value-string-#{i}-#{'x' * 40}\""
    }.join(",") + "}"
    expect(JSON.parse(json)).to eq(Yeptris::Native.load_json(json, false))
  end

  it "holds a 300-pair map under GC.stress (run when YEPTRIS_CANARY_GC=1)" do
    next unless defined?(::Yeptris::Native)
    skip "set YEPTRIS_CANARY_GC=1 (slow: stress-collects every allocation)" unless ENV["YEPTRIS_CANARY_GC"]

    json = "{" + (0...300).map { |i|
      "\"key-#{i}\":\"value-string-#{i}-#{'x' * 40}\""
    }.join(",") + "}"
    want = JSON.parse(json)
    GC.stress = true
    3.times do
      expect(Yeptris::Native.load_json(json, false)).to eq(want)
    end
  ensure
    GC.stress = false
  end
end
