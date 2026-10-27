# frozen_string_literal: true

# The stdlib ports: test_null.rb + test_numeric.rb (#179's audit).
# stdlib names, function for function.
RSpec.describe "Psych null and numerics (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  # --- test_null.rb ---
  it "test_null_list" do
    expect(::Psych.load("---\n- ~\n- null\n-\n- Null\n- NULL\n")).to eq([nil] * 5)
  end

  # --- test_numeric.rb ---
  it "test_load_float_with_dot" do
    expect(::Psych.load("--- 1.")).to eq(1.0)
  end

  it "test_non_float_with_0" do
    expect(::Psych.load("--- 090")).to eq("090")
  end

  it "test_does_not_attempt_numeric" do
    expect(::Psych.load("--- 4 roses")).to eq("4 roses")
    expect(::Psych.load("--- 1.1.1")).to eq("1.1.1")
  end

  # backwards compatibility kept by stdlib (not to YAML spec)
  it "test_string_with_commas" do
    expect(::Psych.load("--- 12,34,56")).to eq(123_456)
  end

  # strict_integer: is a Psych.load kwarg today — xit until the
  # load-kwargs port (#179)
  xit "test_string_with_commas_with_strict_integer" do
    expect(::Psych.load("--- 12,34,56", strict_integer: true)).to eq("12,34,56")
  end

  # BigDecimal: needs the visitor's !ruby/object:BigDecimal revival +
  # YAMLTree's dump arm (#179's object-revival port)
  xit "test_big_decimal_tag" do
    decimal = BigDecimal("12.34")
    expect(::Psych.dump(decimal)).to match(/!ruby\/object:BigDecimal/)
  end
end
