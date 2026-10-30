# frozen_string_literal: true

# Regression spec (found by lutaml-jsonschema CI, x64-mingw-ucrt
# 0.6.34.2): the JSON fallback route references MARSHAL_STRICT_DUP_KEYS,
# but the constant was never defined — it only ever evaluated on lanes
# where the native ext answers first. On the windows lane (FFI present,
# no Ruby-version-matched native build) the reference raised NameError
# and failed every parse.

RSpec.describe "Yeptris::FFI::MARSHAL_STRICT_DUP_KEYS" do
  it "is defined with the engine's flag value (yeptris.h: 1u)" do
    expect(defined?(::Yeptris::FFI::MARSHAL_STRICT_DUP_KEYS)).not_to be_nil
    expect(::Yeptris::FFI::MARSHAL_STRICT_DUP_KEYS).to eq(1)
  end

  it "drives the marshal engine's strict-duplicate-key behavior" do
    skip "marshal engine unavailable" unless
      defined?(::Yeptris::FFI::MARSHAL_STRICT_DUP) &&
      ::Yeptris::FFI::MARSHAL_STRICT_DUP

    flags = ::Yeptris::FFI::MARSHAL_STRICT_DUP_KEYS

    # the flag itself enforces strictness at the engine, whatever the
    # host json gem's resolved default is
    expect { ::Yeptris::JSON.marshal_engine('{"a":1,"a":2}', flags) }
      .to raise_error(::Yeptris::JSON::ParseError)
    expect(::Yeptris::JSON.marshal_engine('{"a":1,"a":2}', 0))
      .to eq("a" => 2)

    expect(::Yeptris::JSON.marshal_engine('{"a":[1,2]}', flags))
      .to eq("a" => [1, 2])
  end
end

# Regression spec (found by lutaml-jsonschema CI, x64-mingw-ucrt with
# 0.6.34.3): the C pre-scan kept one key table for the whole stream,
# cleared on MAP_OPEN, and never grew it past 16 slots. A parent key
# equal to a key in a preceding child object was a false duplicate
# (every ordinary schema on lanes without a native ext), a parent
# duplicate after a nested object was missed, and a 17th distinct key
# in one object probed forever.
RSpec.describe "marshal engine strict duplicate-key scan" do
  before do
    skip "marshal engine unavailable" unless
      defined?(::Yeptris::FFI::MARSHAL_STRICT_DUP) &&
      ::Yeptris::FFI::MARSHAL_STRICT_DUP
  end

  let(:flags) { ::Yeptris::FFI::MARSHAL_STRICT_DUP_KEYS }

  it "checks keys per map, not across nested objects" do
    expect(::Yeptris::JSON.marshal_engine('{"a":{"b":1},"b":2}', flags))
      .to eq("a" => { "b" => 1 }, "b" => 2)
    expect(::Yeptris::JSON.marshal_engine('{"a":[{"b":1}],"b":2}', flags))
      .to eq("a" => [{ "b" => 1 }], "b" => 2)
  end

  it "raises for a duplicate in a map that contains a nested object" do
    expect do
      ::Yeptris::JSON.marshal_engine('{"p":1,"a":{"x":1},"p":2}', flags)
    end.to raise_error(::Yeptris::JSON::ParseError, /duplicate key/)
  end

  it "grows past sixteen distinct keys in one object" do
    json = JSON.generate((0...64).to_h { |i| ["k#{i}", i] })
    expect(::Yeptris::JSON.marshal_engine(json, flags).size).to eq(64)
  end
end

# Regression spec (yeptris-ruby#333, found by lutaml-openapi's corpus
# round-trip on windows lanes with 0.6.50.0): the value stream's slot
# rule toggled the key parity for SEQUENCE entries too, so every
# odd-position array element carried is_key=1 and the strict-dup scan
# false-flagged arrays with a repeated value at two odd positions —
# plain JSON.generate output answered "duplicate key in object" (the
# engine fix rides the 0.6.51 line; JSON.load's marshal route and the
# engine call are pinned here).
RSpec.describe "marshal engine strict scan vs sequence entries" do
  before do
    skip "marshal engine unavailable" unless
      defined?(::Yeptris::FFI::MARSHAL_STRICT_DUP) &&
      ::Yeptris::FFI::MARSHAL_STRICT_DUP
  end

  let(:flags) { ::Yeptris::FFI::MARSHAL_STRICT_DUP_KEYS }

  it "accepts arrays with repeated values at odd positions" do
    expect(::Yeptris::JSON.marshal_engine('["a", "b", "a"]', flags))
      .to eq(["a", "b", "a"])
    expect(::Yeptris::JSON.marshal_engine('{"k": ["x", "y", "x"]}', flags))
      .to eq("k" => ["x", "y", "x"])
    expect(::Yeptris::JSON.marshal_engine('[[1, 2, 1], [1, 2, 1]]', flags))
      .to eq([[1, 2, 1], [1, 2, 1]])
  end

  it "accepts the same key across sibling maps inside one array" do
    expect(::Yeptris::JSON.marshal_engine('[{"m": 1}, {"m": 2}]', flags))
      .to eq([{ "m" => 1 }, { "m" => 2 }])
  end

  it "still raises for true duplicate keys in maps" do
    expect { ::Yeptris::JSON.marshal_engine('{"a": 1, "a": 2}', flags) }
      .to raise_error(::Yeptris::JSON::ParseError)
  end

  it "loads such documents through the JSON entry (the #333 surface)" do
    doc = JSON.generate("features" => [
      { "type" => "movement", "coords" => [1, 2, 1, 2] },
      { "type" => "movement", "coords" => [1, 2, 1, 2] },
    ])
    expect(Yeptris::JSON.load(doc)).to eq(JSON.parse(doc))
  end
end
