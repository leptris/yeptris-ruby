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
