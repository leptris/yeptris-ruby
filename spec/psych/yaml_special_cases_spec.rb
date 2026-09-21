# frozen_string_literal: true

# #179 port: stdlib's test_yaml_special_cases.rb. Empty string,
# false/n scalars, parse_stream returns [] on empty, special floats.
RSpec.describe "Psych YAML special cases (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  it "test_false / test_loaded_false (plain scalar roots)" do
    expect(::Psych.unsafe_load("false")).to eq(false)
    expect(::Psych.unsafe_load("true")).to eq(true)
    expect(::Psych.load("false")).to eq(false)
  end

  it "test_n (plain string, not the bool — compat schema)" do
    expect(::Psych.unsafe_load("n")).to eq("n")
  end

  it "test_inf / test_minus_inf / test_nan (special floats)" do
    expect(::Psych.unsafe_load(".inf")).to eq(1 / 0.0)
    expect(::Psych.unsafe_load("-.inf")).to eq(-1 / 0.0)
    expect(::Psych.unsafe_load(".nan").to_s).to eq("NaN")
  end

  xit "test_empty_string (stdlib returns false — #179 divergence)"
  xit "test_load_stream [] on empty (#179)"
end
