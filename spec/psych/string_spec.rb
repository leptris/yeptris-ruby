# frozen_string_literal: true

# #179 port: stdlib's test_string.rb. Most tests assert encoding/scalar
# behaviors the C resolver + visit_scalar already cover; the standalone
# ScalarScanner surface is a feature gap (#179).
RSpec.describe "Psych strings (the stdlib port)" do
  before(:all) { require "yeptris/psych/drop_in" }

  it "test_psych_load_string" do
    expect(::Psych.load("---\n'hello'\n")).to eq('hello')
    expect(::Psych.load("---\n'read a \"quoted\" string'\n")).to eq('read a "quoted" string')
  end

  it "test_psych_load_unicode_string" do
    expect(::Psych.load("---\n'日本語テキスト'\n")).to eq('日本語テキスト')
    expect(::Psych.load("--- \u00e9\n").encoding).to eq(Encoding::UTF_8)
  end

  it "test_psych_dump_string" do
    expect(::Psych.dump('hello')).to eq("--- hello\n")
    expect(::Psych.load(::Psych.dump("a\nb"))).to eq("a\nb")
  end

  it "test_string_with_backslash" do
    loaded = ::Psych.load(%!and a \\ backslash!)
    expect(loaded).to eq('and a \\ backslash')
    expect(::Psych.load(::Psych.dump('a\\b'))).to eq('a\\b')
  end
end
