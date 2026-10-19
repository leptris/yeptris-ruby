# frozen_string_literal: true

# Canary for the native JSON materializer SIGSEGV seen from
# lutaml/lutaml-jsonschema (see the segfault + tape-fallback issues
# filed 2026-10). The crash is a GC/heap-layout heisenbug: the
# identical loop crashed 6/6 fresh processes one day (identical fault
# address 0x63732d7265707968 — document string bytes read as a
# pointer) and survived everything the next day.
#
# NOT part of the default suite — an in-parse SIGSEGV kills the whole
# rspec process, which is the signal, but it must never gate CI.
# Run it with:
#
#   YEPTRIS_SEGFAULT_CANARY=1 bundle exec rspec spec/json_native_segfault_canary_spec.rb
#
# Survival prints a digest so runs are comparable; a crash aborts with
# the faulting address in the native backtrace.

require "json"

RSpec.describe "Yeptris::JSON native materializer segfault canary" do
  it "survives churn + repeated loads of a schema-like document" do
    skip "diagnostic canary; set YEPTRIS_SEGFAULT_CANARY=1" unless ENV["YEPTRIS_SEGFAULT_CANARY"]
    skip "native materializer not loaded (tape fallback)" unless defined?(::Yeptris::Native)

    # Schema-like shape mirroring the crashing fixture: nested $defs,
    # long prose strings containing the byte sequences seen at the
    # faulting address ("hyper-sc..."), escapes, numbers, booleans.
    entries = Array.new(1200) do |i|
      %("def#{i}":{"id":"urn:hypermedia:object:#{i}","type":"object",) +
        %("description":"hyper-scaled resource #{i} for the corpus — é🎉 \\t \\u00e9",) +
        %("properties":{"name":{"type":"string"},"count":{"type":"integer"},) +
        %("tags":{"type":"array","items":{"type":"string"}},"ok":{"type":"boolean"},) +
        %("child":{"$ref":"#/definitions/def#{(i + 1) % 1200}"}},"required":["name"],) +
        %("additionalProperties":{"type":["string","null"]}})
    end
    doc = +( "{\"$schema\":\"http://json-schema.org/draft-04/schema#\",\"definitions\":{" ) +
          entries.join(",") +
          "},\"root\":{\"$ref\":\"#/definitions/def0\"}}"
    raise "corpus generation broken" unless doc.bytesize > 400_000

    # Heap churn: alternate json-gem and yeptris parses, discarding
    # the trees — this matches both crashing sessions (the bench
    # crashed on the first native parse after a json-gem parse).
    6.times do
      JSON.parse(doc)
      GC.start
      ::Yeptris::JSON.load(doc)
    end

    # The crash loop: sparse stdout keeps allocation cadence close to
    # the original crashing shape (puts every 25th iteration).
    $stdout.sync = true
    300.times do |i|
      ::Yeptris::JSON.load(doc)
      puts "canary iter #{i + 1} ok" if (i + 1) % 25 == 0
    end

    expect(
      "survived #{doc.bytesize} bytes x 306 loads; " \
      "GC.count=#{GC.count.inspect} threads=#{Thread.list.size}"
    ).to be_a(String)
  end
end
