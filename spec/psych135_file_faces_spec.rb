# frozen_string_literal: true

require "spec_helper"
require "yeptris/psych"
require "tempfile"

# The stdlib file/stream-level singleton faces (#135) and the
# binary-input UTF-8 tagging contract.
RSpec.describe "Yeptris::Psych file faces" do
  let(:path) do
    f = Tempfile.new(%w[yep135 .yaml])
    f.write("i: 1\ns: x\nd: 1979-05-27\n")
    f.close
    f.path
  end

  after { File.delete(path) rescue nil }

  it "load_file / safe_load_file / unsafe_load_file / parse_file" do
    expect(Yeptris::Psych.load_file(path)).to eq("i" => 1, "s" => "x", "d" => Date.new(1979, 5, 27))
    expect(Yeptris::Psych.safe_load_file(path)).to eq("i" => 1, "s" => "x", "d" => Date.new(1979, 5, 27))
    expect(Yeptris::Psych.unsafe_load_file(path)).to eq("i" => 1, "s" => "x", "d" => Date.new(1979, 5, 27))
    expect(Yeptris::Psych.parse_file(path).children).not_to be_empty
  end

  it "load_file honors fallback: on ENOENT" do
    expect(Yeptris::Psych.load_file("/nonexistent-135.yaml", fallback: true)).to be_falsey
    expect { Yeptris::Psych.load_file("/nonexistent-135.yaml") }.to raise_error(Errno::ENOENT)
  end

  it "safe_dump produces the dump output" do
    expect(Yeptris::Psych.safe_dump("a" => 1)).to eq("---\na: 1\n")
  end

  it "load_stream returns every document" do
    docs = Yeptris::Psych.load_stream("--- 1\n--- 2\n")
    expect(docs).to eq([1, 2])
  end

  it "safe_load of a BINARY input tags non-ASCII scalars UTF-8" do
    src = "s: café\n".dup.force_encoding(Encoding::ASCII_8BIT)
    r = Yeptris::Psych.safe_load(src)
    expect(r["s"]).to eq("café")
    expect(r["s"].encoding).to eq(Encoding::UTF_8)
  end
end
