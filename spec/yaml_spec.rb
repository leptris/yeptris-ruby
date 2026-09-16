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
