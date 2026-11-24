# frozen_string_literal: true

# The artifact smoke battery runs against the repo lib here (the
# release workflows run the same script against the INSTALLED gem —
# TODO.restructure/40). If the battery rots, the release gate rots
# with it; this spec is the anti-rot (the README-smoke lesson).

RSpec.describe "scripts/gem-smoke.rb" do
  it "passes against the repo lib" do
    # YEPTRIS_SMOKE_REPO_LIB: the dev face. A dev-built per-minor
    # bundle whose libyeptris dependency lives outside the gem's
    # loader paths may not activate here — the face reports the
    # diagnostic and continues on the FFI ladder (the PLATFORM-gem
    # face keeps the hard shipped-but-loaded gate). The diagnostic
    # is asserted so the require-error detail never rots silent.
    # Open3 with an env hash: the bash env-prefix form is not
    # command syntax on Windows cmd.
    require "open3"
    # ENV.to_h.merge: ENV#merge itself is Ruby 3.3+ — the suite floor
    # is older, and there ENV is a plain Object (the universal forms).
    child_env = ENV.to_h.merge("YEPTRIS_SMOKE_REPO_LIB" => "1")
    out, status = Open3.capture2(
      child_env,
      RbConfig.ruby, "scripts/gem-smoke.rb", Yeptris::VERSION.to_s
    )
    out = out.to_s
    expect(status).to be_success, out
    expect(out).to include("SMOKE PASS yeptris #{Yeptris::VERSION}")
    expect(out).to match(%r{smoke: native_\d+_\d+ present but not loaded \(.+\)}m)
      .or include("native+ffi")
  end

  it "fails loudly on a version mismatch" do
    out = `#{RbConfig.ruby} scripts/gem-smoke.rb 0.0.0 2>&1`
    expect($?).not_to be_success
    expect(out).to include("SMOKE FAIL version")
  end
end
