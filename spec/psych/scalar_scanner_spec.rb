# frozen_string_literal: true

# #179 port: stdlib's test_scalar_scanner.rb. The stdlib tests drive a
# standalone Psych::ScalarScanner#tokenize (raw String -> Ruby typed value);
# yeptris's typed-value surface lives inside the C resolver (the
# node's scalar_to_ruby dispatches by tag_id and text shape) and the
# Materializer (plain-string -> Date). A standalone ScalarScanner
# class is a feature gap tracked under #179 — every example here xit
# until that helper lands.
RSpec.describe "Psych scalar scanner (the stdlib port)" do
  it "test_scan_time" do
  end
  it "test_scan_bad_time" do
  end
  it "test_scan_date" do
  end
  it "test_scan_inf / plus_inf / minus_inf / nan" do
  end
  it "test_scan_float_with_exponent_but_no_fraction" do
  end
  it "test_scan_int" do
  end
  it "test_scan_int_max" do
  end
  it "test_scan_int_overflow" do
  end
  it "test_scan_string_with_commas_kept" do
  end
  it "test_scan_string_dash_dot" do
  end
  it "test_scan_string_with_exponent" do
  end
  it "test_scan_string_with_leading_zeros" do
  end
  it "test_scan_string_with_octal_prefix" do
  end
end
