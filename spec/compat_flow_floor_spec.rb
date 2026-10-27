# frozen_string_literal: true

require "psych" # the oracle is STDLIB Psych, never the drop-in
require "yeptris"
require "yeptris/yaml"
require "yeptris/valueml"

RSpec.describe "the compat schema's flow grammar parity" do
  # The block-level flow indent floor (9C9N/VJP3) is a yaml-test-suite
  # rule libyaml never enforced: real-world locale files close
  # multi-line flow collections at their parent's column. The compat
  # schema is the psych/libyaml parity surface every Ruby adapter
  # rides, so it must accept what libyaml accepts — isodoc's
  # i18n-en.yaml is the real-world breaker (metanorma-standoc CI,
  # 2026-09-26).
  breaker = <<~YAML
    obligation: Obligation
    admonition: {
      danger: Danger,
      warning: Warning,
      editorial: Editorial Note
    }
    locality: {
                      section: Section,
                      clause: Clause
                    }
    after: yes
  YAML

  it "parses a multi-line flow closed at the parent's column" do
    expect(Yeptris::YAML.load(breaker)).to eq(
      "obligation" => "Obligation",
      "admonition" => { "danger" => "Danger", "warning" => "Warning",
                        "editorial" => "Editorial Note" },
      "locality" => { "section" => "Section", "clause" => "Clause" },
      "after" => true
    )
  end

  it "matches stdlib Psych on the 9C9N shape" do
    yml = "flow: [a,\nb,\nc]"
    expect(Yeptris::YAML.load(yml)).to eq(Psych.safe_load(yml))
  end

  it "matches stdlib Psych on the real-world locale file" do
    path = File.expand_path("fixtures/compat_flow_floor_i18n.yaml", __dir__)
    yml = File.read(path)
    expect(Yeptris::YAML.load(yml)).to eq(Psych.safe_load(yml))
  end

  it "drains the same shapes through the ValueML surfaces" do
    yml = "flow: [a,\nb,\nc]\nclose0: {\n  x: 1\n}\n"
    expect(Yeptris::ValueML.load(yml, schema: :compat_11)).to eq(
      "flow" => %w[a b c], "close0" => { "x" => 1 }
    )
    expect(Yeptris::ValueML.load_all(yml, schema: :compat_11).first).to include(
      "close0" => { "x" => 1 }
    )
  end

  it "keeps the strict core-schema floor" do
    expect { Yeptris::Document.parse("flow: [a,\nb,\nc]", schema: :core_12) }
      .to raise_error(Yeptris::ParseError, /inconsistent indentation/)
  end
end
