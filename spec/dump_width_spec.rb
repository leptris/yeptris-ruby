# frozen_string_literal: true

# The width-folding audit fix (audit round 2): the emitter options
# width/indent were accepted and discarded on the Psych face
# (YAMLTree.create / Psych.dump). They now ride the engine's
# yeptris_emit_options.best_width (13B): flow collections wrap after a
# value when the line exceeds the width; 0 rides the engine default of
# 80. With the engine's #1257 flip the default also folds BLOCK plain
# and single-quoted scalars at that width (psych/libyaml stored-file
# parity); literal/folded block scalars are unaffected by the knob,
# and a negative width is the unwrap. The behavior probe below gates
# the fold-default claims — binding CI rides the newest RELEASED
# engine tag, where the flip may not have shipped yet.
require "yeptris"
require "yeptris/psych"

RSpec.describe "emitter width folding" do
  FLOW_DOC = "a: [#{("1, " * 30).chomp}]\n"

  # behavior probe, not a version guess: post-flip engines fold block
  # plain scalars at the default 80 (output grows interior lines);
  # released engines unwrap (one line — the trailing newline alone
  # does not count)
  FOLD_DEFAULT = begin
    doc = Yeptris::Document.parse("k: #{("word " * 25).strip}\n")
    folded = doc.serialize.lines.size > 1
    doc.free
    folded
  end

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

    it "leaves literal block scalars unaffected" do
      lit = "a: |\n  #{("word " * 30).strip}\n"
      doc = Yeptris::Document.parse(lit)
      expect(doc.serialize(best_width: 20)).to eq(doc.serialize)
      doc.free
    end

    it "folds a plain block scalar only where the width is passed" do
      plain = "a: #{("word " * 30).strip}\n"
      doc = Yeptris::Document.parse(plain)
      if FOLD_DEFAULT
        # #1257: width 20 folds the value; the default 80 folds it less
        expect(doc.serialize(best_width: 20).lines.size)
          .to be > doc.serialize.lines.size
      else
        expect(doc.serialize(best_width: 20)).to eq(doc.serialize)
      end
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

    it "keeps block output without fold points unaffected by width" do
      # space-free scalars ("1") have no interior space, so no fold
      # can trigger in block output on either side of the #1257 flip
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

  describe "the #1257 fold default (engine flip, capability-gated)" do
    before { skip "engine predates the #1257 fold flip" unless FOLD_DEFAULT }

    it "folds block plain scalars at 80 by default (psych parity)" do
      out = ::Yeptris::Psych.dump({ "k" => ("word " * 25).strip })
      expect(out.lines.size).to be > 2
      # the continuation re-indents to parent_col + best_indent (2);
      # the visitor face emits the --- marker, so the value spans
      # lines 1..n and the last line is the folded continuation
      expect(out.lines[-1]).to start_with("  ")
      expect(::Yeptris::YAML.valid?(out)).to be(true)
    end

    it "re-parses the folded value to the same string" do
      value = ("word " * 25).strip
      out = ::Yeptris::Psych.dump({ "k" => value })
      expect(Yeptris::YAML.load(out)).to eq({ "k" => value })
    end

    it "line_width: -1 unwraps (psych's spelling) on the dump face" do
      value = ("word " * 25).strip
      expect(Yeptris::YAML.dump({ "k" => value }, header: true, width: -1))
        .to eq("---\nk: #{value}\n")
    end

    it "line_width: -1 unwraps on the Psych face" do
      obj = { "k" => ("word " * 25).strip }
      # stdlib Psych.dump always carries the --- marker; the unwrap is
      # the marker plus the single value line
      expect(::Yeptris::Psych.dump(obj, line_width: -1).lines.size).to eq(2)
    end

    it "serialize(best_width: -1) reaches the engine clamp (not dropped)" do
      value = ("word " * 25).strip
      doc = Yeptris::Document.parse("k: #{value}\n")
      expect(doc.serialize(best_width: -1)).to eq("k: #{value}\n")
      doc.free
    end
  end
end
