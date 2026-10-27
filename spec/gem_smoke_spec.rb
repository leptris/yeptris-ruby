# frozen_string_literal: true

# The artifact smoke battery runs against the repo lib here (the
# release workflows run the same script against the INSTALLED gem —
# TODO.restructure/40). If the battery rots, the release gate rots
# with it; this spec is the anti-rot (the README-smoke lesson).

RSpec.describe "scripts/gem-smoke.rb" do
  it "passes against the repo lib" do
    out = `#{RbConfig.ruby} scripts/gem-smoke.rb #{Yeptris::VERSION} 2>&1`
    expect($?).to be_success, out
    expect(out).to include("SMOKE PASS yeptris #{Yeptris::VERSION}")
  end

  it "fails loudly on a version mismatch" do
    out = `#{RbConfig.ruby} scripts/gem-smoke.rb 0.0.0 2>&1`
    expect($?).not_to be_success
    expect(out).to include("SMOKE FAIL version")
  end
end
