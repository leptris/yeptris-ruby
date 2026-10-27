# frozen_string_literal: true

require "spec_helper"
require "yeptris/json"

# The Descriptor plan walk (#293 slice two): a row shape compiled
# once, applied in one native pass — differential against JSON.load
# (the rows assembled from columns must equal the parsed document
# restricted to the planned leaves).
RSpec.describe "Yeptris::JSON::Descriptor" do
  let(:rows_json) do
    '[{"id":1,"name":"one","score":1.5,"ok":true},
      {"id":2,"name":"two","score":2.25,"ok":false},
      {"id":3,"name":null,"score":null,"ok":null}]'
  end

  let(:descriptor) do
    Yeptris::JSON::Descriptor.build(
      kind: :seq,
      children: [
        { name: "id", kind: :int },
        { name: "name", kind: :str },
        { name: "score", kind: :float },
        { name: "ok", kind: :bool },
      ]
    )
  end

  it "compiles once and walks typed columns" do
    result = descriptor.walk(rows_json)
    expect(result.count).to eq(3)
    expect(result.column("id")).to eq([1, 2, 3])
    expect(result.column("name")).to eq(["one", "two", nil])
    expect(result.column("score")).to eq([1.5, 2.25, nil])
    expect(result.column("ok")).to eq([true, false, nil])
  end

  it "columns match JSON.load restricted to the planned leaves" do
    result = descriptor.walk(rows_json)
    parsed = ::Yeptris::JSON.load(rows_json)
    expect(result.to_a).to eq(parsed.map { |row| row.slice("id", "name", "score", "ok") })
  end

  it "the map-root form walks rows under the path key" do
    doc = '{"items":[{"id":1},{"id":2}],"other":true}'
    map_desc = Yeptris::JSON::Descriptor.build(kind: :map, path: "items",
                                     children: [{ name: "id", kind: :int }])
    result = map_desc.walk(doc)
    expect(result.column("id")).to eq([1, 2])
  end

  it "missing leaves and unknown keys leave their slots nil" do
    doc = '[{"id":1,"extra":"x"},{"id":2},{"other":true}]'
    result = descriptor.walk(doc)
    expect(result.column("id")).to eq([1, 2, nil])
    expect(result.column("name")).to eq([nil, nil, nil])
    expect(result.count).to eq(3)
  end

  it "shape disagreement raises (rows container missing)" do
    expect { descriptor.walk('{"a":1}') }.to raise_error(Yeptris::JSON::Descriptor::Error)
    expect { descriptor.walk('42') }.to raise_error(Yeptris::JSON::Descriptor::Error)
  end

  it "malformed JSON raises ParseError" do
    expect { descriptor.walk('[{"id":1,]') }.to raise_error(::Yeptris::JSON::ParseError)
  end

  it "at/to_a/each_row expose the row form" do
    result = descriptor.walk(rows_json)
    expect(result.at(0)).to eq("id" => 1, "name" => "one", "score" => 1.5, "ok" => true)
    expect(result.at(3)).to be_nil
    expect(result.to_a.size).to eq(3)
    expect(result.each_row.to_a).to eq(result.to_a)
    expect(result.to_ruby).to eq(result.to_a)
  end

  it "string escapes decode through the JSON span reader" do
    doc = '[{"name":"a\\"b\\n\\u00e9"}]'
    str_desc = Yeptris::JSON::Descriptor.build(kind: :seq, children: [{ name: "name", kind: :str }])
    expect(str_desc.walk(doc).column("name")).to eq(['a"b' + "\n" + "é"])
  end

  it "leptris vocabulary aliases: :collection root, :scalar leaves" do
    doc = '[{"name":"x"}]'
    desc = Yeptris::JSON::Descriptor.build(kind: :collection,
                                 children: [{ name: "name", kind: :scalar }])
    expect(desc.walk(doc).column("name")).to eq(["x"])
  end

  it "rejects malformed descriptors at build time" do
    expect { Yeptris::JSON::Descriptor.build(kind: :bogus, children: [{ name: "a", kind: :int }]) }
      .to raise_error(ArgumentError)
    expect { Yeptris::JSON::Descriptor.build(kind: :seq, children: []) }.to raise_error(ArgumentError)
    expect { Yeptris::JSON::Descriptor.build(kind: :seq, children: [{ name: "a", kind: :bogus }]) }
      .to raise_error(ArgumentError)
  end

  it "reads IO inputs like the other surfaces" do
    io = StringIO.new(rows_json)
    expect(descriptor.walk(io).column("id")).to eq([1, 2, 3])
  end

  it "the lutaml-model shape: 5000 rows hydrate from columns" do
    items = Array.new(5000) { |i| { "id" => i, "name" => "item-#{i}", "score" => i * 0.5 } }
    doc = ::JSON.generate("items" => items)
    desc = Yeptris::JSON::Descriptor.build(kind: :map, path: "items",
                                 children: [
                                   { name: "id", kind: :int },
                                   { name: "name", kind: :str },
                                   { name: "score", kind: :float },
                                 ])
    result = desc.walk(doc)
    expect(result.count).to eq(5000)
    expect(result.column("id")).to eq(items.map { |i| i["id"] })
    expect(result.column("name")).to eq(items.map { |i| i["name"] })
    expect(result.column("score")).to eq(items.map { |i| i["score"] })
  end
end
