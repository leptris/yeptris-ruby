# frozen_string_literal: true

# Standalone face requires (#300): `require "yeptris/cbor"` and
# `require "yeptris/json"` must work without the parent preloaded —
# availability probes (serialbench's per-process adapters) depend on
# module load order otherwise. Each face now bootstraps with
# `require "yeptris"` (the pattern yeptris/psych already used).
RSpec.describe "standalone face requires (#300)" do
  let(:lib_path) do
    ENV["YEPTRIS_LIB_PATH"] ||
      Dir[File.expand_path("../lib/platform/*/libyeptris.*", __dir__)].first ||
      File.expand_path("../../yeptris/build-validate/src/libyeptris.dylib", __dir__)
  end
  let(:lib) { File.expand_path("../lib", __dir__) }

  def standalone(prog)
    env = { "YEPTRIS_LIB_PATH" => lib_path }
    system(env, RbConfig.ruby, "-I", lib, "-e", prog)
  end

  it "yeptris/cbor loads and round-trips without the parent preloaded" do
    prog = 'require "yeptris/cbor"; d = Yeptris::CBOR.load(Yeptris::CBOR.dump({"a" => 1})); raise unless d == {"a" => 1}'
    expect(standalone(prog)).to be(true)
  end

  it "yeptris/json loads and parses without the parent preloaded" do
    prog = 'require "yeptris/json"; raise unless Yeptris::JSON.load("{\"a\":1}") == {"a" => 1}'
    expect(standalone(prog)).to be(true)
  end

  it "yeptris/psych still loads standalone (the pattern both faces converged on)" do
    prog = 'require "yeptris/psych"; raise unless Yeptris::YAML.load("a: 1") == {"a" => 1}'
    expect(standalone(prog)).to be(true)
  end
end
