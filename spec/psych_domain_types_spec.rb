# frozen_string_literal: true

require "spec_helper"
require "yeptris/psych"

# The third registry (the relaton/lutaml report: 26x undefined method
# domain_types under the rebind; stdlib psych carries load_tags,
# dump_tags, AND domain_types).
RSpec.describe "Yeptris::Psych.domain_types" do
  after do
    Yeptris::Psych.domain_types.clear
  end

  it "exists as a writable class-level registry" do
    expect(Yeptris::Psych.domain_types).to eq({})
    Yeptris::Psych.domain_types["tag:mygem:v1"] = ["tag:mygem:v1", ->(_k, r) { r }]
    expect(Yeptris::Psych.domain_types.size).to eq(1)
  end

  it "add_domain_type registers the normalized keys" do
    blk = ->(_k, r) { r }
    Yeptris::Psych.add_domain_type("mygem", "shape", &blk)
    expect(Yeptris::Psych.domain_types).to have_key("tag:mygem:shape")
    expect(Yeptris::Psych.domain_types).to have_key("tag:shape")
  end

  it "applies the registered block over the revived result" do
    Yeptris::Psych.add_domain_type("mygem", "upper", &lambda { |_k, r|
      r.is_a?(::Hash) ? r.transform_values { |v| v.to_s.upcase } : r
    })
    obj = Yeptris::Psych.unsafe_load("--- !mygem:upper\nword: hello\n")
    expect(obj).to eq("word" => "HELLO")
  end

  it "add_tag writes both registries" do
    klass = Class.new do
      include Yeptris::Psych::Encodable
      attr_accessor :v

      def encode_with(coder)
        coder["v"] = @v
      end

      def init_with(coder)
        @v = coder["v"]
      end
    end
    Yeptris::Psych.add_tag("!mygem/tagged", klass)
    expect(Yeptris::Psych.load_tags["!mygem/tagged"]).to eq(klass.name)
    expect(Yeptris::Psych.dump_tags[klass]).to eq("!mygem/tagged")
  end
end
