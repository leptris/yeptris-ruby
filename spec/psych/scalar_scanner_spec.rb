# frozen_string_literal: true

# #179 port: stdlib's test_scalar_scanner.rb. The standalone
# Psych::ScalarScanner ships (lib/yeptris/psych/scalar_scanner.rb) with
# stdlib's regexes, precedence, and edge verdicts — the examples below
# are the stdlib assertions, verbatim.
require "date"
require "yeptris/psych"

RSpec.describe "Psych scalar scanner (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  def ss
    @ss ||= Psych::ScalarScanner.new(Psych::ClassLoader.new)
  end

  it "test_scan_time" do
    {
      '2001-12-15T02:59:43.1Z' => Time.utc(2001, 12, 15, 02, 59, 43, 100_000),
      '2001-12-14t21:59:43.10-05:00' => Time.utc(2001, 12, 15, 02, 59, 43, 100_000),
      '2001-12-14 21:59:43.10 -5' => Time.utc(2001, 12, 15, 02, 59, 43, 100_000),
      '2001-12-15 2:59:43.10' => Time.utc(2001, 12, 15, 02, 59, 43, 100_000),
      '2011-02-24 11:17:06 -0800' => Time.utc(2011, 02, 24, 19, 17, 06)
    }.each do |time_str, time|
      expect(ss.tokenize(time_str)).to eq(time)
    end
  end

  it "test_scan_bad_time" do
    ['2001-12-15T02:59:73.1Z',
     '2001-12-14t90:59:43.10-05:00',
     '2001-92-14 21:59:43.10 -5',
     '2001-12-15 92:59:43.10',
     '2011-02-24 81:17:06 -0800'].each do |time_str|
      expect(ss.tokenize(time_str)).to eq(time_str)
    end
  end

  it "test_scan_bad_dates" do
    expect(ss.tokenize('2000-15-01')).to eq('2000-15-01')
    expect(ss.tokenize('2000-10-51')).to eq('2000-10-51')
    expect(ss.tokenize('2000-10-32')).to eq('2000-10-32')
  end

  it "test_scan_good_edge_date / test_scan_bad_edge_date" do
    expect(ss.tokenize('2000-1-31')).to eq(Date.strptime('2000-1-31', '%Y-%m-%d'))
    expect(ss.tokenize('2000-11-31')).to eq('2000-11-31')
  end

  it "test_scan_date" do
    token = ss.tokenize('1980-12-16')
    expect(token.year).to eq(1980)
    expect(token.month).to eq(12)
    expect(token.day).to eq(16)
  end

  it "test_scan_inf / plus_inf / minus_inf / nan" do
    expect(ss.tokenize('.inf')).to eq(1 / 0.0)
    expect(ss.tokenize('+.inf')).to eq(1 / 0.0)
    expect(ss.tokenize('-.inf')).to eq(-1 / 0.0)
    expect(ss.tokenize('.nan')).to be_nan
  end

  it "test_scan_float_with_exponent_but_no_fraction" do
    expect(ss.tokenize('0.E+0')).to eq(0.0)
  end

  it "test_scan_null / test_scan_symbol / booleans" do
    expect(ss.tokenize('null')).to be_nil
    expect(ss.tokenize('~')).to be_nil
    expect(ss.tokenize('')).to be_nil
    expect(ss.tokenize(':foo')).to eq(:foo)
    expect(ss.tokenize('true')).to be true
    expect(ss.tokenize('yes')).to be true
    expect(ss.tokenize('no')).to be false
  end

  it "test_scan_sexagesimal_int / float" do
    expect(ss.tokenize('190:20:30')).to eq(685_230)
    expect(ss.tokenize('190:20:30.15')).to eq(685_230.15)
  end

  it "test_scan_not_sexagesimal" do
    expect(ss.tokenize('00:00:00:00:0f')).to eq('00:00:00:00:0f')
    expect(ss.tokenize('00:00:00:00:00')).to eq('00:00:00:00:00')
    expect(ss.tokenize('00:00:00:00:00.0')).to eq('00:00:00:00:00.0')
  end

  it "test_scan_float / ints / int_max / int_overflow" do
    expect(ss.tokenize('1.2')).to eq(1.2)
    expect(ss.tokenize('123')).to eq(123)
    expect(ss.tokenize('9223372036854775807')).to eq(9_223_372_036_854_775_807)
    expect(ss.tokenize('9223372036854775808')).to eq(9_223_372_036_854_775_808)
  end

  it "test_scan_strings (underscores, numbers, legacy delimiters)" do
    expect(ss.tokenize('_100')).to eq('_100')
    expect(ss.tokenize('450D')).to eq('450D')
    expect(ss.tokenize('100_')).to eq('100_')
    expect(ss.tokenize('0x_,_')).to eq('0x_,_')
    expect(ss.tokenize('+0__,,')).to eq('+0__,,')
    expect(ss.tokenize('-0b,_,')).to eq('-0b,_,')
  end

  it "test_scan_strings_with_strict_int_delimiters" do
    scanner = Psych::ScalarScanner.new(Psych::ClassLoader.new, strict_integer: true)
    expect(scanner.tokenize('0x___')).to eq('0x___')
    expect(scanner.tokenize('+0____')).to eq('+0____')
    expect(scanner.tokenize('-0b___')).to eq('-0b___')
  end

  it "test_scan_string_with_commas_kept / dash_dot" do
    expect(ss.tokenize('a, b')).to eq('a, b')
    expect(ss.tokenize('-.inf')).to eq(-1 / 0.0)
    expect(ss.tokenize('-.')).to eq('-.')
  end
end
