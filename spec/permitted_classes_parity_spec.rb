# frozen_string_literal: true

# yeptris-ruby#258: the Psych drop-in ignored permitted_classes —
# !ruby/symbol raised DisallowedClass even with Symbol permitted
# (the documented psych API for symbol-tagged documents), and the
# scanner-coercion primitives were rejected outright. These pins hold
# the psych-faithful matrix: every row diffed against stdlib Psych.

RSpec.describe "Psych drop-in permitted_classes parity (#258)" do
  def yep(yaml, permitted:)
    Yeptris::Psych.safe_load(yaml, permitted_classes: permitted)
  rescue Yeptris::Psych::DisallowedClass
    :disallowed
  end

  def psy(yaml, permitted:)
    Psych.safe_load(yaml, permitted_classes: permitted)
  rescue Psych::DisallowedClass
    :disallowed
  end

  SYMBOL_DOC = "---\nfoo: !ruby/symbol bar\n"

  {
    "ruby/symbol permitted" => [SYMBOL_DOC, [Symbol]],
    "ruby/symbol not permitted" => [SYMBOL_DOC, []],
    "ruby/string with no permissions" => ["---\nfoo: !ruby/string baz\n", []],
    "ruby/integer with no permissions" => ["---\nfoo: !ruby/integer 42\n", []],
    "ruby/float with no permissions" => ["---\nfoo: !ruby/float 1.5\n", []],
    "unknown ruby object" => ["---\nfoo: !ruby/object:Nope::Missing\n  a: 1\n", []],
    "unpermitted ruby object" => ["---\nfoo: !ruby/object:OpenStruct\n  a: 1\n", []],
  }.each do |name, (yaml, permitted)|
    it "matches psych: #{name}" do
      expect(yep(yaml, permitted: permitted)).to eq(psy(yaml, permitted: permitted))
    end
  end

  it "materializes a permitted symbol" do
    expect(yep(SYMBOL_DOC, permitted: [Symbol])).to eq("foo" => :bar)
  end

  it "keeps unsafe_load's symbol behavior" do
    expect(Yeptris::Psych.unsafe_load(SYMBOL_DOC)).to eq(Psych.unsafe_load(SYMBOL_DOC))
  end
end
