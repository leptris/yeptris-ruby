# frozen_string_literal: true

RSpec.describe "ValueML typed-string conversion" do
  # ONE conversion law for every str column (ValueML.str_to_value):
  # the pair fast path drifted and handed big ints / symbol keys
  # through as Strings (audit 2026-10-31). The record walk and the
  # columnar walk must agree.
  SRC = "99999999999999999999: :symval\nsmall: :ok\n"

  it "rebuilds big-int keys and values in the record walk" do
    expect(Yeptris::ValueML.load_all(SRC).first)
      .to eq(999_999_999_999_999_999_99 => :symval, "small" => :ok)
  end

  it "rebuilds big-int keys and values in the columnar walk" do
    expect(Yeptris::ValueML.load_all_columns(SRC).first)
      .to eq(999_999_999_999_999_999_99 => :symval, "small" => :ok)
  end

  it "keeps quoted ':x' a String" do
    expect(Yeptris::ValueML.load_all_columns("k: ':quoted'\n").first)
      .to eq("k" => ":quoted")
  end
end
