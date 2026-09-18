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
puts "PUBLISHED GEM OK #{RUBY_VERSION} #{RUBY_PLATFORM} yeptris=#{Yeptris::VERSION}"
