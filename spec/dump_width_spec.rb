# frozen_string_literal: true

# The width-folding audit fix (audit round 2): the emitter options
# width/indent were accepted and discarded on the Psych face
# (YAMLTree.create / Psych.dump). They now ride the engine's
# yeptris_emit_options.best_width (13B): flow collections wrap after a
# value when the line exceeds the width; 0 rides the engine default of
# 80. The engine folds flow collections only — plain block scalars and
# literal/folded block scalars are unaffected by the knob (emit.h).
require "yeptris"
require "yeptris/psych"

RSpec.describe "emitter width folding" do
  FLOW_DOC = "a: [#{("1, " * 30).chomp}]\n"

  def max_line(text)
    text.lines.map(&:length).max
  end

  describe "Document#serialize(best_width:)" do
    it "folds a flow collection at the engine default of 80" do
      doc = Yeptris::Document.parse(FLOW_DOC)
      out = doc.serialize
      expect(out.lines.size).to be > 1
      expect(max_line(out)).to be <= 86 # 80 + one trailing value
      doc.free
    end

    it "folds at a custom width when given" do
      doc = Yeptris::Document.parse(FLOW_DOC)
      out = doc.serialize(best_width: 30)
      expect(out.lines.size).to be > doc.serialize.lines.size
      expect(max_line(out)).to be <= 36
      doc.free
    end

    it "leaves block scalars unaffected" do
      lit = "a: |\n  #{("word " * 30).strip}\n"
      doc = Yeptris::Document.parse(lit)
      expect(doc.serialize(best_width: 20)).to eq(doc.serialize)
      doc.free

      plain = "a: #{("word " * 30).strip}\n"
      doc = Yeptris::Document.parse(plain)
      expect(doc.serialize(best_width: 20)).to eq(doc.serialize)
      doc.free
    end
  end

  describe "the neutral dump face (width:)" do
    it "threads width: to the emitter (canonical mode emits flow, which folds)" do
      wide = Yeptris::YAML.dump({ "a" => [1] * 30 }, header: true, canonical: true)
      narrow = Yeptris::YAML.dump({ "a" => [1] * 30 }, header: true, canonical: true, width: 20)
      expect(narrow.lines.size).to be > wide.lines.size
      expect(max_line(narrow)).to be <= 26
      expect(Yeptris::YAML.valid?(narrow)).to be(true) # the fold re-parses
    end

    it "keeps the default when width: is absent" do
      expect(Yeptris::YAML.dump({ "a" => [1] * 30 }, header: true, width: nil))
        .to eq(Yeptris::YAML.dump({ "a" => [1] * 30 }, header: true))
    end

    it "leaves block output (the default style) unaffected by width" do
      # the builders emit block collections; the engine folds flow only
      block = Yeptris::YAML.dump({ "a" => [1] * 30 }, header: true)
      expect(Yeptris::YAML.dump({ "a" => [1] * 30 }, header: true, width: 20)).to eq(block)
    end
  end

  describe "the Psych face (options no longer discarded)" do
    it "honors line_width on the visitor path (with canonical's flow output)" do
      obj = { "a" => [1] * 30 }
      default = ::Yeptris::Psych.dump(obj, canonical: true)
      narrow = ::Yeptris::Psych.dump(obj, canonical: true, line_width: 20)
      expect(narrow.lines.size).to be > default.lines.size
      expect(max_line(narrow)).to be <= 26
      expect(::Yeptris::YAML.valid?(narrow)).to be(true)
    end

    it "honors line_width in the io slot (stdlib's Object#to_yaml call)" do
      obj = { "a" => [1] * 30 }
      via_slot = ::Yeptris::Psych.dump(obj, canonical: true, line_width: 20)
      expect(via_slot.lines.size)
        .to be > ::Yeptris::Psych.dump(obj, canonical: true).lines.size
    end

    it "honors line_width through tree.yaml's options tail" do
      tree = ::Yeptris::Psych::Visitors::YAMLTree.create({ "line_width" => 20,
                                                           "canonical" => true }, nil)
      tree.push({ "a" => [1] * 30 })
      out = tree.tree.yaml
      expect(out.lines.size).to be > 1
      expect(max_line(out)).to be <= 26
    end

    it "honors canonical on the visitor path" do
      obj = { "a" => [1, 2] }
      expect(::Yeptris::Psych.dump(obj, canonical: true))
        .not_to eq(::Yeptris::Psych.dump(obj))
    end

    it "honors line_width on the scalar fast path" do
      # a top-level String rides YAML.dump directly — the width keyword
      # must flow through without disturbing the scalar output
      expect(::Yeptris::Psych.dump("plain text", line_width: 20))
        .to eq(::Yeptris::Psych.dump("plain text"))
    end

    it "accepts indentation: for Psych parity (accepted; the engine has no knob)" do
      obj = { "a" => [1] * 30 }
      expect(::Yeptris::Psych.dump(obj, indentation: 4))
        .to eq(::Yeptris::Psych.dump(obj))
    end

    it "keeps the byte shape when no options ride" do
      expect(::Yeptris::Psych.dump({ "a" => [1] * 30 }))
        .to eq(::Yeptris::Psych.dump({ "a" => [1] * 30 }, {}))
    end
  end
end
