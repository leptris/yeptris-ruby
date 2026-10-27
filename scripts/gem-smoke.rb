# frozen_string_literal: true

# Artifact smoke (TODO.restructure/40): release-time proof that the
# BUILT GEM is semantically correct on whatever engine it ships —
# the 0.1.13.5 train shipped a gem whose native path failed its own
# spec suite because only local (working-tree) runs were green.
#
# Usage: ruby scripts/gem-smoke.rb <expected_version>
#
# The CALLER controls isolation: release workflows install the .gem
# into a scratch GEM_HOME so `require "yeptris"` resolves to the
# installed gem (never a repo checkout); the spec suite runs this
# same battery against the repo lib (spec/gem_smoke_spec.rb) so the
# battery itself cannot rot. This is a canary battery, not the
# suite — full semantics stay in rspec.

def assert_eq(got, want, what)
  raise "SMOKE FAIL #{what}: got #{got.inspect}, want #{want.inspect}" unless got == want
end

expected = ARGV[0] or raise "usage: ruby scripts/gem-smoke.rb <expected_version>"
require "yeptris"
assert_eq(Yeptris::VERSION, expected, "version")

spec = Gem.loaded_specs["yeptris"]
if spec && Dir.glob(File.join(spec.gem_dir, "lib", "yeptris", "native.{bundle,so}")).any?
  # a platform gem carries the bundle: it MUST activate (a silent
  # fallback would ship the perf win dead — the libruby-link bug)
  raise "SMOKE FAIL native bundle shipped but not loaded" unless defined?(::Yeptris::Native)
end
engine = defined?(::Yeptris::Native) ? "native+ffi" : "ffi"

json = Yeptris::JSON
assert_eq(json.load('{"a": 1e3}'), { "a" => 1000.0 }, "json float shape (spec 10.3.2)")
assert_eq(json.load('{"n": -9223372036854775808}')['n'], -9223372036854775808, "json int64 floor")
assert_eq(json.load('{"b": 92233720368547758089999}')['b'], 92233720368547758089999, "json big int exact")
assert_eq(json.load('{"u": "\\u00e9\\ud83d\\ude00"}')['u'], "\u00e9" + [0x1F600].pack("U"), "json unicode escapes (pair combines)")
assert_eq(json.load("[[[[1]]]]"), [[[[1]]]], "json nesting")
assert_eq(json.load('{"k": "\\u0041"}')['k'], "A", "json escaped ascii fold")
["{\"a\":}", "[1,]", '{"a":1}{', "nul"].each do |bad|
  begin
    json.load(bad)
    raise "SMOKE FAIL json reject: #{bad.inspect} parsed"
  rescue Yeptris::JSON::ParseError
    nil
  end
end

yaml = Yeptris::YAML
assert_eq(yaml.load("k: 1e3\n", schema: :core_12), { "k" => 1000.0 }, "core_12 spec typing")
assert_eq(yaml.load("k: 1e3\n", schema: :compat_11), { "k" => "1e3" }, "compat_11 Psych quirk")
assert_eq(yaml.load("k: 0x3A\n", schema: :core_12), { "k" => 58 }, "core_12 hex")
assert_eq(yaml.load(%(["a", 1])), ["a", 1], "flow")
tree = { "n" => 2, "f" => 0.5, "s" => "héllo", "a" => [1, "two"] }
assert_eq(yaml.load(yaml.dump(tree)), tree, "dump/load round-trip")
doc = Yeptris::Document.parse("k: 1e3\n", schema: :core_12)
assert_eq(doc.root["k"].to_ruby, 1000.0, "node surface schema-conditioned")
doc.free

puts "SMOKE PASS yeptris #{expected} (#{engine})"
