# frozen_string_literal: true


RSpec.describe "BulkBuilder.plain_string? mirrors the LOADING schema" do
  it "plain exactly when compat_11 re-reads the text as a String" do
    # the oracle is the reader, not the builder: synthesized nodes type
    # under core12, but the gem loads with compat_11 (Psych parity) —
    # the dumper must quote what the READER would reshape
    probes = [
      "hello", "value 1", "a-b_c.d", "42", "-7", "1.5", "1e3", "0x1F", "010",
      "1_000", "190:20:30", "yes", "no", "on", "off", "true", "null", "~",
      "y", "n", "<<", "2020-01-02", "2020-01-02 03:04:05", "#comment",
      "- lead", "k: v", "trail ", ":name", "-5", "?x", "a#b", "a #b", "",
      "with: colon", "0b1010", ".inf", ".nan", "safe", "1:2:3", "Z9_./x",
    ]
    probes.each do |text|
      psych_text = Psych.dump(text)
      psych_plain = !psych_text.include?("'") && !psych_text.include?('"')
      expect(Yeptris::YAML::BulkBuilder.plain_string?(text))
        .to eq(psych_plain), "#{text.inspect}: Psych quotes=#{!psych_plain}"
    end
  end
end
