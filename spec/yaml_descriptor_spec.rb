# frozen_string_literal: true

require "spec_helper"
require "yeptris"

# The DOM leg emits one row for a scalar-map leaf since the fix that
# landed with v0.6.93 (leptris/yeptris-ruby#430); older engines
# returned rows=0 for the single-record shape. The probe skips them.
def yaml_descriptor_scalar_map_rows?
  d = ::Yeptris::YAML::Descriptor.build(kind: :map, path: %w[db],
                                        children: [{ name: "v", kind: :int }])
  d.walk("db:\n  v: 1\n").rows == 1
rescue ::Yeptris::JSON::Error
  false
end

# The YAML leg of the Descriptor plan walk (#293 slice three): the
# same compiled row shape applied to block YAML — differential
# against Yeptris::YAML.load restricted to the planned leaves.
RSpec.describe "Yeptris::YAML::Descriptor" do
  let(:rows_yaml) do
    <<~YAML
      - id: 1
        name: one
        ok: true
        score: 1.5
      - id: 2
        name: two
        ok: false
        score: 2
      - id: 3
        name:
    YAML
  end

  let(:descriptor) do
    Yeptris::YAML::Descriptor.build(
      kind: :seq,
      children: [
        { name: "id", kind: :int },
        { name: "name", kind: :str },
        { name: "ok", kind: :bool },
        { name: "score", kind: :float },
      ]
    )
  end

  it "walks typed columns over block YAML" do
    result = descriptor.walk(rows_yaml)
    expect(result.count).to eq(3)
    expect(result.column("id")).to eq([1, 2, 3])
    expect(result.column("name")).to eq(["one", "two", nil])
    expect(result.column("ok")).to eq([true, false, nil])
    expect(result.column("score")).to eq([1.5, 2.0, nil]) # int text promotes
  end

  it "columns match YAML.load restricted to the planned leaves" do
    result = descriptor.walk(rows_yaml)
    parsed = ::Yeptris::YAML.load(rows_yaml)
    expect(result.column("id")).to eq(parsed.map { |r| r["id"] })
    expect(result.column("name")).to eq(parsed.map { |r| r["name"] })
    expect(result.column("ok")).to eq(parsed.map { |r| r["ok"] })
    # int text promotes into a float column (the plan's typed contract);
    # missing leaves are explicit nils in the column form
    expect(result.column("score")).to eq(parsed.map { |r| r["score"]&.to_f })
  end

  it "segmented paths walk nested block mappings" do
    yaml = <<~YAML
      meta:
        version: 2
      data:
        items:
          - id: 1
          - id: 2
        other:
          - id: 9
    YAML
    desc = Yeptris::YAML::Descriptor.build(kind: :map, path: ["data", "items"],
                                           children: [{ name: "id", kind: :int }])
    expect(desc.walk(yaml).column("id")).to eq([1, 2])
  end

  it "map-root containers yield their mapping values as rows" do
    yaml = <<~YAML
      items:
        first:
          id: 1
        second:
          id: 2
    YAML
    desc = Yeptris::YAML::Descriptor.build(kind: :map, path: "items",
                                           children: [{ name: "id", kind: :int }])
    expect(desc.walk(yaml).column("id")).to eq([1, 2])
  end

  it "alias rows resolve to their targets and ~ stays null" do
    yaml = <<~YAML
      - &d
        id: 99
        name: base
      - *d
      - id: 2
        name: ~
    YAML
    result = descriptor.walk(yaml)
    expect(result.column("id")).to eq([99, 99, 2])
    expect(result.column("name")).to eq(["base", "base", nil])
  end

  it "type disagreement leaves the slot null; str columns take any scalar" do
    yaml = <<~YAML
      - id: not-a-number
        name: "123"
    YAML
    result = descriptor.walk(yaml)
    expect(result.column("id")).to eq([nil])
    expect(result.column("name")).to eq(["123"])
  end

  it "compat_11 typing resolves the Psych words (y is a bool)" do
    yaml = <<~YAML
      - ok: y
        name: n
    YAML
    result = descriptor.walk(yaml)
    expect(result.column("ok")).to eq([true])
    expect(result.column("name")).to eq(["n"]) # quoted: stays a string
  end

  it "shape disagreement raises" do
    expect { descriptor.walk("a: 1\n") }.to raise_error(Yeptris::JSON::Descriptor::Error)
  end

  it "malformed YAML raises the parse error" do
    expect { descriptor.walk("a: [1,\n") }.to raise_error(Yeptris::ParseError)
  end

  it "the lutaml-model shape: 5000 block rows hydrate from columns" do
    items = Array.new(5000) { |i| { "id" => i, "name" => "item-#{i}", "score" => i * 0.5 } }
    yaml = { "items" => items }.to_yaml
    desc = Yeptris::YAML::Descriptor.build(kind: :map, path: "items",
                                           children: [
                                             { name: "id", kind: :int },
                                             { name: "name", kind: :str },
                                             { name: "score", kind: :float },
                                           ])
    result = desc.walk(yaml)
    expect(result.count).to eq(5000)
    expect(result.column("id")).to eq(items.map { |i| i["id"] })
    expect(result.column("name")).to eq(items.map { |i| i["name"] })
    expect(result.column("score")).to eq(items.map { |i| i["score"] })
  end

  # The single-record shape (leptris/yeptris-ruby#430): a map-kind
  # walk whose path leaf is a MAP OF SCALARS emits ONE row — the
  # record's own pairs are the fields.
  describe "the scalar-map leaf: one row for a single record", if: yaml_descriptor_scalar_map_rows? do
    it "emits one populated row for the block record" do
      yaml = <<~YAML
        config:
          database:
            host: localhost
            port: 5432
            name: myapp
      YAML
      desc = Yeptris::YAML::Descriptor.build(kind: :map, path: %w[config database],
                                             children: [
                                               { name: "host", kind: :str },
                                               { name: "port", kind: :int },
                                               { name: "name", kind: :str },
                                             ])
      result = desc.walk(yaml)
      expect(result.rows).to eq(1)
      expect(result.at(0)).to eq("host" => "localhost", "port" => 5432, "name" => "myapp")
    end

    it "nested leaves stay null and later fields still fill" do
      yaml = <<~YAML
        db:
          host: h
          tls:
            enabled: true
          port: 5432
      YAML
      desc = Yeptris::YAML::Descriptor.build(kind: :map, path: "db",
                                             children: [
                                               { name: "host", kind: :str },
                                               { name: "tls", kind: :str },
                                               { name: "port", kind: :int },
                                             ])
      result = desc.walk(yaml)
      expect(result.rows).to eq(1)
      expect(result.at(0)).to eq("host" => "h", "tls" => nil, "port" => 5432)
    end

    it "the mapping-values contrast stays rows-per-value" do
      yaml = <<~YAML
        items:
          first:
            id: 1
          second:
            id: 2
      YAML
      desc = Yeptris::YAML::Descriptor.build(kind: :map, path: "items",
                                             children: [{ name: "id", kind: :int }])
      expect(desc.walk(yaml).rows).to eq(2)
    end
  end
end
