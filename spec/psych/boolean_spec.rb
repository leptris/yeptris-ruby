# frozen_string_literal: true

# Port of psych/test/psych/test_boolean.rb (loading semantics).
# Excluded: the libfyaml (YAML 1.2 backend) branches — our compat_11
# surface IS the libyaml semantics those tests guard against.

RSpec.describe "Psych port: booleans" do
  # true/false in both 1.1 and 1.2
  %w[true True TRUE].each do |truth|
    it "loads #{truth} as true" do
      expect(Yeptris::YAML.load("--- #{truth}")).to be(true)
    end
  end

  %w[false False FALSE].each do |falsy|
    it "loads #{falsy} as false" do
      expect(Yeptris::YAML.load("--- #{falsy}")).to be(false)
    end
  end

  # yes/on: booleans under 1.1 (libyaml backend semantics)
  %w[yes Yes YES on On ON].each do |truth|
    it "loads #{truth} as true (YAML 1.1)" do
      expect(Yeptris::YAML.load("--- #{truth}")).to be(true)
    end
  end

  %w[no No NO off Off OFF].each do |falsy|
    it "loads #{falsy} as false (YAML 1.1)" do
      expect(Yeptris::YAML.load("--- #{falsy}")).to be(false)
    end
  end

  # Syck (and Psych 5.4) keep single chars as strings
  it "loads y/Y as strings" do
    expect(Yeptris::YAML.load("--- y")).to eq("y")
    expect(Yeptris::YAML.load("--- Y")).to eq("Y")
  end

  it "loads n/N as strings" do
    expect(Yeptris::YAML.load("--- n")).to eq("n")
    expect(Yeptris::YAML.load("--- N")).to eq("N")
  end

  it "loads the Norway problem under 1.1 semantics (no -> false)" do
    expect(Yeptris::YAML.load("country: no")).to eq("country" => false)
  end

  it "keeps the Norway problem as strings under 1.2 semantics" do
    expect(Yeptris::YAML.load("country: no", schema: :core_12))
      .to eq("country" => "no")
    expect(Yeptris::YAML.load("- yes\n- no\n- on\n- off\n", schema: :core_12))
      .to eq(%w[yes no on off])
  end
end
