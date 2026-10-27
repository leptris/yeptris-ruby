# frozen_string_literal: true

# #180: the error taxonomy under the rebind — every load surface a
# consumer can reach through the top-level YAML module (stdlib YAML
# delegates to ::Psych, which IS ours after the drop-in) must raise
# Psych::SyntaxError for invalid YAML, exactly as stdlib does. A
# leaked Yeptris::ParseError escapes every `rescue Psych::SyntaxError`
# written against stdlib semantics (relaton-cli's collection ls
# crashed on it).
RSpec.describe "the error taxonomy (stdlib parity)" do
  before(:all) do
    require "yaml" # the consumer order: stdlib YAML first, then the rebind
    require "yeptris/psych/drop_in"
  end

  BAD = "x: <a href=\"foo\">\n  y: 1\n".freeze

  it "Psych.load raises SyntaxError" do
    expect { ::Psych.load(BAD) }.to raise_error(::Psych::SyntaxError)
  end

  it "Psych.unsafe_load raises SyntaxError" do
    expect { ::Psych.unsafe_load(BAD) }.to raise_error(::Psych::SyntaxError)
  end

  it "Psych.parse raises SyntaxError" do
    expect { ::Psych.parse(BAD) }.to raise_error(::Psych::SyntaxError)
  end

  it "YAML.load_file raises SyntaxError (stdlib YAML delegates to the rebound Psych)" do
    ::File.write(::File::NULL == "NUL" ? "tmp_bad_180.yml" : "/tmp/bad_180.yml", BAD)
    path = ::File.exist?("/tmp/bad_180.yml") ? "/tmp/bad_180.yml" : "tmp_bad_180.yml"
    begin
      expect { ::YAML.load_file(path) }.to raise_error(::Psych::SyntaxError)
      expect { ::YAML.unsafe_load_file(path) }.to raise_error(::Psych::SyntaxError)
    ensure
      ::File.delete(path) if ::File.exist?(path)
    end
  end

  it "an undefined anchor raises AnchorNotDefined (stdlib's class)" do
    expect { ::Psych.load("bar:\n  << : *foo\n", aliases: true) }
      .to raise_error(::Psych::AnchorNotDefined)
  end
end
