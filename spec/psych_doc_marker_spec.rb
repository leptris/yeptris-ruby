# frozen_string_literal: true

# The document-marker parity (issue: Version#to_yaml round-trip):
# Yeptris::Psych.dump must emit the leading --- exactly as libyaml's
# Psych does — marker-alone for collections, marker-line for scalar
# roots. Pinned as exact bytes: the drop-in spec rebinds ::Psych
# process-wide, so comparing against the live Psych here is not
# reliable across spec load order.
RSpec.describe "Yeptris::Psych.dump document marker" do
  it "emits the leading marker for collections" do
    expect(Yeptris::Psych.dump("version" => "1.2.3")).to eq("---\nversion: 1.2.3\n")
    expect(Yeptris::Psych.dump([1, 2])).to eq("---\n- 1\n- 2\n")
    expect(Yeptris::Psych.dump("a" => { "b" => [true] })).to eq("---\na:\n  b:\n    - true\n")
  end

  it "rides scalar roots on the marker line (libyaml form)" do
    expect(Yeptris::Psych.dump("plain")).to eq("--- plain\n")
    expect(Yeptris::Psych.dump(42)).to eq("--- 42\n")
    expect(Yeptris::Psych.dump(true)).to eq("--- true\n")
    expect(Yeptris::Psych.dump(1.5)).to eq("--- 1.5\n")
  end

  it "round-trips dumped documents (the marker parses back)" do
    obj = { "name" => "yeptris", "parts" => [1, 2.5, "three"] }
    dumped = Yeptris::Psych.dump(obj)
    expect(dumped).to start_with("---\n")
    expect(Yeptris::Psych.load(dumped)).to eq(obj)
  end
end
