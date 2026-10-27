# Round-trips the PUBLISHED gem (installed from rubygems by the caller)
# across the surfaces users touch first: YAML load, datetime mapping,
# the Psych drop-in (the process-wide surface — #318's amplifier), and
# JSON load. Fails loudly on any missing-constant/packaging skew.
require "yeptris"
require "yeptris/psych/drop_in"
require "date"

src = <<~YAML
  i: 1
  s: x
  d: 1979-05-27
  f: 1.5
  arr: [1, 2, {n: 3}]
YAML

doc = Yeptris::YAML.load(src)
raise "int" unless doc["i"] == 1
raise "str" unless doc["s"] == "x"
raise "date" unless doc["d"] == Date.new(1979, 5, 27)
raise "float" unless doc["f"] == 1.5
raise "nested" unless doc["arr"].last["n"] == 3

# the psych surface (process-wide under the rebind): plain Hash#to_yaml
# is the exact call that died on the broken mingw packages (#318)
h = { "content" => "x", "nest" => { "x" => [1, 2] } }
y = h.to_yaml
raise "to_yaml" unless y.start_with?("---") && y.include?("nest:")
raise "psych round" unless ::Psych.load(y) == h
raise "json" unless Yeptris::JSON.load('{"a": [1, 2]}') == { "a" => [1, 2] }

# The strict-JSON duplicate-key contract (issue #37, canon's CI):
# Yeptris::JSON.load must follow the RESOLVED json gem's own verdict —
# json >= 3 raises, 2.x last-wins. Lane diagnostics ride the failure:
# this is the only Windows-executing guard for the lane selection.
# Exercise the json >= 3 lane explicitly: the verdict only bites when
# the resolved json gem raises (canon's CI resolved json 3.1.0; legs
# whose default json is 2.x pass vacuously).
system("gem install json -v '~> 3.0' --no-document --conservative >/dev/null 2>&1 || true")
require "json"
dup_src = '{"a":1,"a":2}'
stdlib_dup = begin
  JSON.parse(dup_src)
rescue JSON::ParserError
  :raised
end
yep_dup = begin
  Yeptris::JSON.load(dup_src)
rescue StandardError
  :raised
end
if yep_dup != stdlib_dup
  marshal = begin
    ::Yeptris::FFI::MARSHAL_STRICT_DUP
  rescue StandardError
    :n_a
  end
  strict = begin
    ::Yeptris::JSON::STRICT_DUPLICATE_KEYS
  rescue StandardError
    :n_a
  end
  warn "dup-contract lane: Native=#{defined?(::Yeptris::Native).inspect} " \
       "MARSHAL_STRICT_DUP=#{marshal.inspect} " \
       "STRICT_DUPLICATE_KEYS=#{strict.inspect} " \
       "json=#{::JSON::VERSION} " \
       "yeptris=#{Gem.loaded_specs['yeptris']&.version}"
  raise "duplicate-key verdict drift: stdlib=#{stdlib_dup.inspect} yeptris=#{yep_dup.inspect}"
end
puts "PUBLISHED GEM OK #{RUBY_VERSION} #{RUBY_PLATFORM} yeptris=#{Yeptris::VERSION}"
