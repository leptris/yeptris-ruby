# frozen_string_literal: true

require "psych" # the oracle is STDLIB Psych, never the drop-in

RSpec.describe "BulkBuilder string_style mirrors Psych.dump" do
  it "quotes exactly as stdlib Psych's visit_String does" do
    # string_style is the quoting table both dump builders share
    # (yaml_tree#visit_String's matrix). The oracle is stdlib
    # Psych.dump: :plain when the output rides bare, :single for
    # single quotes, :double for double quotes.
    probes = [
      "hello", "value 1", "a-b_c.d", "42", "-7", "1.5", "1e3", "0x1F", "010",
      "1_000", "190:20:30", "yes", "no", "on", "off", "true", "null", "~",
      "y", "n", "<<", "2020-01-02", "2020-01-02 03:04:05", "#comment",
      "- lead", "k: v", "trail ", ":name", "-5", "?x", "a#b", "a #b", "",
      "with: colon", "0b1010", ".inf", ".nan", "safe", "1:2:3", "Z9_./x",
      "1.2.3", "1.2.3.4", "08", "09", "0777", "0x", "5014",
      # leading-zero hours reshape under compat_11 (psych's
      # ScalarScanner parses "07:00:00" plain as Integer — lutaml-model
      # round-trips hit this); psych dumps them quoted
      "07:00:00", "00:30", "09:59:59", "0:1",
    ]
    probes.each do |text|
      psych_text = Psych.dump(text)
      psych_style =
        if psych_text.include?("'")
          :single
        elsif psych_text.include?('"')
          :double
        else
          :plain
        end
      expect(Yeptris::YAML::BulkBuilder.string_style(text))
        .to eq(psych_style), "#{text.inspect}: Psych says #{psych_style}"
    end
  end
end

RSpec.describe "leading-zero sexagesimal round-trip (compat_11)" do
  it "preserves String through dump+load" do
    ["07:00:00", "00:30", "09:59:59"].each do |text|
      dumped = Yeptris::YAML.dump({"k" => text})
      reloaded = Yeptris::YAML.load(dumped, schema: :compat_11)["k"]
      expect(reloaded).to eq(text), "#{text.inspect} reloaded as #{reloaded.inspect} from #{dumped.inspect}"
      expect(reloaded).to be_a(String)
    end
  end
end

RSpec.describe "Unicode break/BOM strings dump byte-stably (C #494-#497)" do
  it "escapes NEL/LS/PS/FEFF instead of emitting them raw" do
    cases = {
      "b\u0085c" => "\"b\\Nc\"\n",
      "x\u2028y" => "\"x\\Ly\"\n",
      "p\u2029q" => "\"p\\Pq\"\n",
      "a\uFEFFb" => "\"a\\uFEFFb\"\n",
    }
    cases.each do |value, want|
      dumped = Yeptris::YAML.dump(value)
      expect(dumped).to eq(want), "#{value.inspect} dumped as #{dumped.inspect}"
      reloaded = Yeptris::YAML.load(dumped)
      expect(reloaded).to eq(value)
      expect(Yeptris::YAML.dump(reloaded)).to eq(want), "unstable round-trip"
    end
  end

  it "keeps plain values plain (no over-quoting)" do
    expect(Yeptris::YAML.dump("hello world")).to eq("hello world\n")
    expect(Yeptris::YAML.dump({ "k" => "07:00:00" })).to include("'07:00:00'")
  end
end

RSpec.describe "null-valued keys ride bare on both dump faces (yeptris#1264)" do
  # stdlib Psych's KEY path carries the explicit !!str semantics — the
  # 1.1 reshape words (y/n/yes/no) never quote as keys — while the
  # VALUE path reshapes them quoted. The neutral face's string branch
  # shared one table for both slots, quoting "n" keys the visitor face
  # (and stdlib) emit bare.
  it "emits the issue's repro bare on the neutral face" do
    h = { "s" => "line1\nline2", "n" => nil }
    expect(Yeptris::YAML.dump(h, header: true))
      .to eq("---\ns: |-\n  line1\n  line2\nn:\n")
  end

  it "agrees with the Psych face byte-for-byte" do
    [{ "s" => "line1\nline2", "n" => nil }, { "n" => nil },
     { "n" => nil, "s" => "line1\nline2" }, { "y" => 1 }, { "N" => nil }].each do |h|
      expect(Yeptris::YAML.dump(h, header: true)).to eq(Yeptris::Psych.dump(h))
    end
  end

  it "keeps the value path's reshape quoting (stdlib parity)" do
    expect(Yeptris::YAML.dump({ "k" => "n" }, header: true))
      .to eq(Yeptris::Psych.dump({ "k" => "n" }))
    expect(Yeptris::YAML.dump("n", header: true)).to eq("--- \"n\"\n")
  end

  it "round-trips the bare words through load" do
    { "n" => "n", "y" => "y" }.each do |k, v|
      expect(Yeptris::YAML.load(Yeptris::YAML.dump({ k => nil }), schema: :compat_11)[k]).to be_nil
    end
  end
end
