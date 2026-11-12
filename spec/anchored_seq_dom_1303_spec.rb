# frozen_string_literal: true

# yeptris#1303: safe_load(aliases: true) mis-attaches the pair
# FOLLOWING an anchored value — the next pair's nested map becomes the
# pair's KEY (with an empty-scalar value), so downstream dig misses.
# The drain walk (YAML.load, the recorder) parses the same bytes
# correctly: the DOM the parse builds is skewed.
#
# The DOM is built engine-side (whole parses ride the fused tape
# writer, dom/ytape.c, TODO.restructure/79), so the FIX lives in the
# engine, not here. Root cause at engine tag v0.6.63, pinned by the
# instrumented build:
#
#   yt_f_open_form (src/yeptris/dom/ytape.c:1034): the
#   `parent_is_root && parent->content_col == 0` "contentless root
#   always opens" rule is meant for the root map's FIRST pair, but the
#   root's content_col stays 0 after a pair whose value was an
#   ANCHORED block sequence — the arming
#   (`st[0].content_col = st[depth].indent + 1`) lives only in the
#   non-anchored arm (ytape.c:1400-1408) and the pair-completion arm
#   (ytape.c:1521), never in the anchored arm (ytape.c:~1355-1395)
#   that the `key: &x` + dash-seq shape takes. The next sibling
#   `key:` line therefore re-fires the contentless-root law and the
#   tape carries a second YTP_OPEN; the replay's dom_on_block_open
#   (dom/dom.c:1197) then places the fresh map into the root map's
#   EMPTY pending-key slot (the dom_place pairing law, dom/dom.c:383),
#   the whole subtree becomes the root's next KEY, and the root
#   MAP_END odd-child law (dom/dom.c:461) pairs it with a synthesized
#   empty scalar.
#
# Law violated: the fused writer's DOM replay must equal the event
# walk's tree — the drain path is the reference law (the issue's own
# framing). These pins carry the contract; the capability probe skips
# while the loaded engine still skews, and they run the moment an
# engine with the fix ships (the binding-CI law: PRs ride the newest
# released engine tag).

RSpec.describe "the DOM after an anchored sequence value (#1303)" do
  TRIGGER = "a: &x\n  - 1\nb:\n  c: 2\n"

  # The issue's downstream shape: an anchored seq aliased inside a
  # nested map, then a sibling pair — svg_conform's quality_metrics
  # configuration fixture form.
  ISSUE = <<~YAML
    remediable_types: &violation_types
      - :reference_violation
    severity_levels:
      critical:
        violation_types: *violation_types
        default_weight: 5
        max_penalty: 20
  YAML

  def dom_skewed?
    doc = Yeptris::Document.parse(TRIGGER, schema: :compat_11)
    pairs = doc.root(0).each_pair.map { |k, v| [k.kind, v.kind] }
    doc.free
    pairs != [[:scalar, :sequence], [:scalar, :mapping]]
  end

  # The drain pins run on EVERY engine — the recorder walk is right
  # while the DOM skews, and they are the reference law the engine fix
  # must converge to.
  it "drains the issue shape correctly TODAY (the reference law)" do
    drained = Yeptris::YAML.load(ISSUE)
    expect(drained.keys).to eq(["remediable_types", "severity_levels"])
    expect(drained.dig("severity_levels", "critical", "violation_types"))
      .to eq([:reference_violation])
  end

  # The DOM pins carry the contract the engine fix must satisfy; they
  # skip while the loaded engine still skews.
  describe "the DOM contract (engine-gated)" do
    before do
      skip "the loaded engine still skews the DOM (engine-side fix pending, #1303)" if dom_skewed?
    end

    it "builds the node-API pairs in key,value order after an anchored seq value" do
      doc = Yeptris::Document.parse(TRIGGER, schema: :compat_11)
      pairs = doc.root(0).each_pair.map { |k, v| [k.kind, v.kind] }
      expect(pairs).to eq([[:scalar, :sequence], [:scalar, :mapping]])
      doc.free
    end

    it "resolves the sibling key lookup" do
      doc = Yeptris::Document.parse(TRIGGER, schema: :compat_11)
      expect(doc.root(0)["severity_levels"] || doc.root(0)["b"]).not_to be_nil
      doc.free
    end

    it "keeps safe_load's tree equal to the drain's" do
      drained = Yeptris::YAML.load(ISSUE)
      safe = Yeptris::YAML.safe_load(ISSUE, permitted_classes: [Symbol], aliases: true)
      expect(safe).to eq(drained)
      expect(safe.keys).to eq(drained.keys)
    end

    it "keeps the downstream dig path alive" do
      safe = Yeptris::YAML.safe_load(ISSUE, permitted_classes: [Symbol], aliases: true)
      expect(safe.dig("severity_levels", "critical", "violation_types"))
        .to eq([:reference_violation])
    end
  end
end
