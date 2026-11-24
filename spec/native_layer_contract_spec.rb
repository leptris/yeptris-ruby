# frozen_string_literal: true

# The org native-layer contract (leptris-ruby#671, adopted by
# yeptris-ruby#409): the FFI candidate order, the per-minor DOT-FREE
# bundle law with NO unversioned fallback, the named-remedy load
# error, and the single candidate list shared by every face (the
# two-images law).
require "open3"

RSpec.describe "the native-layer contract (leptris-ruby#671)" do
  let(:repo) { File.expand_path("..", __dir__) }
  let(:ffi_rb) { File.join(repo, "lib", "yeptris", "ffi.rb") }
  let(:manifest) { File.join(repo, "lib", "yeptris.rb") }
  let(:extconf) { File.join(repo, "ext", "yeptris_native", "extconf.rb") }

  # the SSOT file carries the minors whitespace-separated
  def supported_minors
    File.read(File.join(repo, "SUPPORTED_MINORS")).split
  end

  describe "the FFI candidate order (clause 1)" do
    it "runs ENV, the vendored tree, the gem-root flat layout, system, and the linker — in that order" do
      # probe with the pin, then RESTORE it — later specs' subprocesses
      # inherit this env (the spec_helper pin is load-bearing)
      saved = ENV["YEPTRIS_LIB_PATH"]
      ENV["YEPTRIS_LIB_PATH"] = "/contract/env-first/libyeptris.dylib"
      candidates = Yeptris::FFI.libleptris_candidates
      if saved
        ENV["YEPTRIS_LIB_PATH"] = saved
      else
        ENV.delete("YEPTRIS_LIB_PATH")
      end

      expect(candidates[0]).to eq("/contract/env-first/libyeptris.dylib")
      # the vendored tree: lib/yeptris/vendor/<platform>/, the running
      # arch first, glibc before musl on linux — no vendor tree on
      # windows (the DLL vendors at the gem root, the contract's flat
      # slot)
      vendor = candidates.grep(%r{/vendor/.+/libyeptris})
      if Gem.win_platform?
        expect(vendor).to be_empty
      else
        expect(candidates[1]).to include("/lib/yeptris/vendor/")
        expect(vendor).not_to be_empty
      end
      linux_order = vendor.grep(/linux/).map { |c| c[%r{vendor/([^/]+)/}m, 1] }
      expect(linux_order).to eq(linux_order & %w[aarch64-linux x86_64-linux
                                                aarch64-linux-musl
                                                x86_64-linux-musl])
      # the flat gem-root slot and the system slot follow, the bare
      # soname last
      expect(candidates[-1]).to eq("yeptris")
      expect(candidates.grep(%r{/usr/local/lib/libyeptris})).not_to be_empty
    end

    it "carries exactly one candidate per vendor platform tag (no dupes)" do
      expect(Yeptris::FFI.libleptris_candidates)
        .to eq(Yeptris::FFI.libleptris_candidates.uniq)
    end

    it "is the SAME list the library actually loaded through (the two-images law)" do
      # ffi_lib consumed libleptris_candidates at require; the method
      # is the single source — re-evaluating it now must still offer
      # the loaded resolution's slot kinds, and with an explicit ENV
      # pin it must reproduce the pin first (nothing re-resolves
      # through a second list)
      expect(Yeptris::FFI.libleptris_candidates.last).to eq("yeptris")
      env = ENV["YEPTRIS_LIB_PATH"]
      expect(Yeptris::FFI.libleptris_candidates).to include(env) if env
    end
  end

  describe "the per-minor DOT-FREE bundle law (clause 2)" do
    it "requires ONLY native_<major>_<minor> — no unversioned, no directory form" do
      src = File.read(manifest)
      expect(src).to include('require "yeptris/native_#{minor}"')
      expect(src).not_to match(/require "yeptris\/native"/)
      expect(src).not_to match(/require "yeptris\/#\{[^}]*\}\/native"/)
      # the fallback is a rescue of that one require — a SECOND require
      # attempt (the unversioned slot the old loader kept) is the
      # wrong-ABI load the contract forbids
      expect(src.scan(/require "yeptris\/native/).size).to eq(1)
    end

    it "names the artifact per minor in the extconf (a source install produces it)" do
      src = File.read(extconf)
      expect(src).to include('create_makefile("yeptris/native_#{minor_us}")')
      expect(src).not_to include('create_makefile("yeptris/native")')
    end

    it "exports the per-minor init symbols (the basename-cut-at-first-dot law)" do
      c = File.read(File.join(repo, "ext", "yeptris_native", "yeptris_native.c"))
      supported_minors.each do |minor|
        expect(c).to include("Init_native_#{minor.tr('.', '_')}")
      end
    end

    it "loads (or falls back to FFI for) exactly the per-minor feature" do
      native_features = $LOADED_FEATURES.grep(%r{/yeptris/native})
      minor = RUBY_VERSION[/\A\d+\.\d+/].tr(".", "_")
      native_features.each do |feature|
        expect(feature).to match(%r{/native_#{minor}\.(bundle|so|dll)\z}),
          "the loader must require yeptris/native_#{minor} only — got #{feature}"
      end
      # the unversioned bundle from an older checkout (lib/yeptris/native.bundle)
      # must NEVER load under the contract loader
      expect(native_features.grep(%r{/native\.(bundle|so|dll)\z})).to be_empty
      # neither may the old per-minor-directory form
      expect(native_features.grep(%r{/yeptris/\d+\.\d+/native\.})).to be_empty
    end
  end

  describe "the named-remedy load error (clause 1's tail)" do
    it "names the remedy when no candidate loads" do
      # a child process whose every slot is broken: the ENV candidate
      # is garbage, and the repo checkout carries no vendored or
      # system copy (CI's workspace root libyeptris.dll on Windows is
      # the one flat slot — there the load legitimately succeeds and
      # the assertion is vacuous)
      out, st = Open3.capture2e(
        { "YEPTRIS_LIB_PATH" => "/contract/nowhere/libyeptris.so" },
        RbConfig.ruby, "-I", File.join(repo, "lib"), "-ryeptris", "-e", "0"
      )
      if st.success?
        skip "a candidate outside this test's control loaded (a system or flat-slot libyeptris)"
      end

      expect(out).to include("YEPTRIS_LIB_PATH")
      expect(out).to include("platform gem")
    end
  end

  describe "packaging (clause 3)" do
    it "keeps SUPPORTED_MINORS the SSOT the loaders and packaging derive from" do
      minors = supported_minors
      expect(minors).not_to be_empty
      minors.each do |minor|
        us = minor.tr(".", "_")
        # the C entry points
        c = File.read(File.join(repo, "ext", "yeptris_native", "yeptris_native.c"))
        expect(c).to include("Init_native_#{us}")
        # the windows build script installs the flat per-minor name
        # (derived per minor, so the artifact literal is the interpolation)
        win = File.read(File.join(repo, "ext", "build_windows_native.rb"))
        expect(win).to include('native_#{minor_us}')
      end
    end
  end

  describe "the gates (clause 4)" do
    it "keeps the glibc-floor gate wired on the release (the artifact's every .so)" do
      release = File.read(File.join(repo, ".github", "workflows", "release.yml"))
      expect(release).to include("Gate the gnu glibc floor")
      expect(release).to include("GLIBC_2")
      expect(release).to include("*/native_*.so")
    end

    it "keeps the engine-lockstep refusal wired (a missing tag fails the release)" do
      release = File.read(File.join(repo, ".github", "workflows", "release.yml"))
      expect(release).to include("refusing to build gems without the fresh engine")
      expect(release).to match(/test -n "\$LOCKSTEP"/)
    end

    it "keeps the per-minor completeness gate on the new flat names" do
      release = File.read(File.join(repo, ".github", "workflows", "release.yml"))
      expect(release).to include("lib/yeptris/native_${m//./_}.so")
    end
  end
end
