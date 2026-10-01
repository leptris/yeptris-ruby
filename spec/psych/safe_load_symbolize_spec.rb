# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Psych.safe_load symbolize_names" do
  let(:yaml) do
    <<~YAML
      id: TEST-001
      docidentifier:
      - content: TEST-001
        type: TEST
      nested:
      - key: value
    YAML
  end

  it "deep-symbolizes keys when symbolize_names is true" do
    res = Yeptris::Psych.safe_load(yaml, symbolize_names: true)
    expect(res.keys).to all(be_a(Symbol))
    expect(res[:docidentifier].first.keys).to all(be_a(Symbol))
    expect(res[:nested].first).to eq(key: "value")
  end

  it "keeps string keys by default" do
    res = Yeptris::Psych.safe_load(yaml)
    expect(res.keys).to all(be_a(String))
  end
end
