# frozen_string_literal: true

# TODO.restructure/22 — the native materializer's spec.
#
# The fused JSON→Ruby path lives in ext/yeptris_native/json_ruby.c;
# it runs ONLY when the extension is loaded (require "yeptris/native"
# is silent on LoadError). When loaded, Yeptris::YAML.load on
# strict-JSON inputs routes through it; YAML inputs keep the FFI
# Marshal ladder (timestamps + Psych quirks).

require "json"
require "benchmark"

# Skipped entirely when the extension is not built (the FFI ladder is
# then the only path — that configuration is covered by the rest of
# the suite).
RSpec.describe "Yeptris::Native", if: defined?(Yeptris::Native) do
  CORPUS = [
    "",
    "{}",
    "[]",
    "null",
    "true",
    "false",
    "0",
    "-1.5",
    "1e5",
    "\"hello\"",
    "{\"id\":1,\"name\":\"x\",\"tags\":[\"a\",\"b\"]}",
    "[1,2,3,{\"a\":[null,true]}]",
    "{\"escaped\":\"a\\nb\\t\\\"c\\\\d\"}",
    "{\"unicode\":\"café ☕\"}",
  ].freeze

  it "reports availability when the extension is loaded" do
    expect(Yeptris::Native::AVAILABLE).to be(true)
  end

  describe "load_json semantics" do
    CORPUS.each do |json|
      it "matches JSON.parse on #{json.inspect[0, 40]}" do
        expected =
          begin
            JSON.parse(json)
          rescue JSON::ParserError
            :parse_error
          end
        actual =
          begin
            Yeptris::Native.load_json(json)
          rescue Yeptris::ParseError
            :parse_error
          end
        expect(actual).to eq(expected)
      end
    end

    it "raises Yeptris::ParseError on invalid JSON" do
      expect { Yeptris::Native.load_json("not json") }.to raise_error(Yeptris::ParseError)
    end

    it "shares interned strings for repeated keys" do
      json = '{"a":1,"a":2,"a":3}'
      obj = Yeptris::Native.load_json(json)
      expect(obj.keys.map(&:object_id).uniq.size).to eq(1)
    end

    it "preserves UTF-8 strings" do
      obj = Yeptris::Native.load_json('{"k":"café ☕"}')
      expect(obj["k"].encoding).to eq(Encoding::UTF_8)
      expect(obj["k"]).to eq("café ☕")
    end
  end

  describe "perf tripwire" do
    # NOT a win-assertion: shared CI runners reproduce yeptris ~1.5x
    # SLOWER than the bundled JSON ext (2 vCPU x86_64, noisy
    # neighbors — TODO.restructure/33), while controlled hardware
    # shows 0.75x faster. The tripwire catches PATHOLOGICAL drift
    # (>= 3x) — the fair benchmark of record is
    # benchmark/json_profile.rb on controlled machines; numbers
    # print below for every CI run.
    it "stays within 3x of JSON.parse on the 152 KB corpus (and reports)" do
      json = +"["
      1400.times do |i|
        json << %({"id":#{i},"name":"item #{i}","tags":["a","b",#{i}],"meta":{"v":#{i * 7},"ok":true,"note":"text #{i} for the corpus"}})
        json << "," unless i == 1399
      end
      json << "]"
      json = json.freeze

      5.times { Yeptris::Native.load_json(json); JSON.parse(json) }
      n = 20
      yeptris = (1..n).map { Benchmark.realtime { Yeptris::Native.load_json(json) } }
      jsonp = (1..n).map { Benchmark.realtime { JSON.parse(json) } }
      yeptris_mean = yeptris.sum / n
      jsonp_mean = jsonp.sum / n
      ratio = yeptris_mean / jsonp_mean
      warn(format("  perf: yeptris %.3f ms vs JSON.parse %.3f ms (%.2fx) on %s",
                  yeptris_mean * 1e3, jsonp_mean * 1e3, ratio, RUBY_PLATFORM))
      expect(ratio).to be < 3.0
    end
  end
end
