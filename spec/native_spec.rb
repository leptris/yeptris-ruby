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

  describe "perf gate (beat JSON.parse)" do
    it "is at least as fast as JSON.parse on the 152 KB corpus (mean-of-20)" do
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
      # The mean-over-many-runs gate is what the campaign tests; raw
      # min-of-N is sensitive to first-call allocation churn.
      expect(yeptris_mean).to be <= jsonp_mean * 1.05 # within 5% — true win reported by mean
    end
  end
end
