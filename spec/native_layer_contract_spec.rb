# frozen_string_literal: true

# The org native-layer contract (leptris-ruby#671's
# NATIVE_LAYER_CONTRACT.md; yeptris-ruby#409): the FFI candidate
# order (env -> vendor tree -> flat lib/ -> system -> soname), the
# per-minor DOT-FREE bundle naming with NO unversioned fallback, and
# the vendor-tree packaging. Each clause mirrors the shipped
# leptris-ruby behavior; divergence is a bug.
require "fileutils"

RSpec.describe "the native-layer contract" do
  describe "FFI.lib_candidates (the single source of truth)" do
    let(:candidates) { Yeptris::FFI.lib_candidates }

    it "leads with the explicit env override" do
      expect(candidates.first).to eq(ENV["YEPTRIS_LIB_PATH"])
    end

    it "compacts the absent env override" do
      env = ENV["YEPTRIS_LIB_PATH"]
      ENV.delete("YEPTRIS_LIB_PATH")
      expect(Yeptris::FFI.lib_candidates.first).not_to be_nil
      expect(Yeptris::FFI.lib_candidates).not_to include(nil)
    ensure
      ENV["YEPTRIS_LIB_PATH"] = env
    end

    it "orders env -> vendor tree -> flat lib/ -> system -> soname" do
      # windows has no vendor tree by contract (the DLL is gem-local
      # flat): assert the rest of the ladder there
      windows_host = RbConfig::CONFIG["host_os"] =~ /mingw|mswin|windows/
      unless windows_host
        # synthesize a vendor cell for THIS platform so the ordering
        # is observable (the dir need not carry a loadable binary —
        # the env override wins long before anything dlopens)
        platform = Yeptris::FFI.vendor_platforms_for(RUBY_PLATFORM).first
        vendor_dir = File.expand_path("../lib/yeptris/vendor/#{platform}", __dir__)
        FileUtils.mkdir_p(vendor_dir)
      end
      begin
        candidates = Yeptris::FFI.lib_candidates
        unless windows_host
          vendor_i = candidates.find_index { |c| c.to_s.include?("/vendor/") }
          flat_i = candidates.find_index { |c| c.to_s.end_with?("lib/libyeptris.dylib") }
          expect(vendor_i).to be < flat_i
        end
        flat_i = candidates.find_index { |c| c.to_s.end_with?("lib/libyeptris.dylib") }
        sys_i = candidates.index("/usr/local/lib/libyeptris.dylib")

        expect(flat_i).to be < sys_i
        expect(candidates.last).to eq("yeptris")
      ensure
        # the fixture cell is the spec's own creation — remove it so
        # a dev checkout gains no stray vendor tree
        FileUtils.rm_rf(vendor_dir) unless windows_host
      end
    end

    it "carries every flat spelling at lib/ (dylib, so, dll)" do
      dir = File.expand_path("../lib", __dir__)
      %w[libyeptris.dylib libyeptris.so libyeptris.dll].each do |name|
        expect(candidates).to include(File.join(dir, name))
      end
    end

    it "resolves the vendor tree under lib/yeptris/vendor/<platform>" do
      Yeptris::FFI.vendor_dirs.each do |dir|
        expect(dir).to match(%r{/lib/yeptris/vendor/[^/]+\z})
      end
    end

    it "is ONE list (the two-images law): the load uses it verbatim" do
      # the library this process loaded must be reachable through the
      # same candidate list — two differently-pathed copies load as
      # two images with split per-document state
      loaded = Yeptris::FFI.ffi_libraries.map(&:name).flatten.compact
      expect(loaded).not_to be_empty
      hit = loaded.any? do |lib|
        candidates.any? { |c| c == lib || File.expand_path(c) == File.expand_path(lib) }
      end
      expect(hit).to be(true)
    end
  end

  describe "vendor_platforms_for (the vendor tree's dir spelling)" do
    def plats(platform)
      Yeptris::FFI.vendor_platforms_for(platform)
    end

    it "maps the darwin platforms" do
      expect(plats("arm64-darwin")).to eq(%w[arm64-darwin])
      expect(plats("x86_64-darwin")).to eq(%w[x86_64-darwin])
    end

    it "tries glibc before musl on linux" do
      expect(plats("x86_64-linux")).to eq(%w[x86_64-linux x86_64-linux-musl])
      expect(plats("aarch64-linux")).to eq(%w[aarch64-linux aarch64-linux-musl])
    end

    it "maps the qemu-adjacent platforms" do
      expect(plats("armv7l-linux")).to eq(%w[arm-linux arm-linux-musl])
      expect(plats("ppc64le-linux")).to eq(%w[ppc64le-linux])
      expect(plats("s390x-linux")).to eq(%w[s390x-linux s390x-linux-musl])
      expect(plats("riscv64-linux-gnu")).to eq(%w[riscv64-linux])
    end

    it "never matches aarch64 as 32-bit arm" do
      expect(plats("aarch64-linux")).not_to include("arm-linux")
    end

    it "answers nothing on windows (the dll is gem-local flat)" do
      expect(plats("x64-mingw-ucrt")).to eq([])
      expect(plats("x64-mingw32")).to eq([])
    end

    it "rebuilds the java engines' lost cpu-os from RbConfig" do
      dirs = plats("x86_64-java")
      # a windows host has no vendor tree by contract — the rebuild
      # answers [] there (the .dll is gem-local flat)
      host_os = RbConfig::CONFIG["host_os"].to_s
      if host_os =~ /mingw|mswin|windows/
        expect(dirs).to eq([])
      else
        expect(dirs).not_to be_empty
        # the rebuilt family names the real host os — the FULL host
        # mapping on linux carries the gnu->musl ladder, whose musl
        # entries end in the "-musl" qualifier, so the os SEGMENT is
        # the contract (a terminal-suffix assertion would misjudge
        # "aarch64-linux-musl", the canonical vendor-dir spelling;
        # no cpu spelling contains "-linux"/"-darwin")
        segment = host_os =~ /darwin/ ? "darwin" : "linux"
        dirs.each do |d|
          expect(d).to match(/-#{segment}/)
        end
      end
    end

    it "answers nothing for unknown platforms" do
      expect(plats("wasm32-unknown")).to eq([])
    end
  end

  describe "the per-minor DOT-FREE bundle naming" do
    it "names the feature native_<major>_<minor> under yeptris/" do
      expect(Yeptris.native_bundle_feature)
        .to eq("yeptris/native_#{RUBY_VERSION[/\A\d+\.\d+/].tr('.', '_')}")
    end

    it "keeps the init-symbol basename dot-free (MRI cuts at the first dot)" do
      basename = File.basename(Yeptris.native_bundle_feature)
      expect(basename).not_to include(".")
      expect(basename).to match(/\Anative_\d+_\d+\z/)
    end
  end

  describe "the packaging pipeline pin (extconf -> script -> loader)" do
    # run 45397564333's failure class: the extension built its per-minor
    # bundle fine and every packaging leg still died at "no ext bundle
    # native_<minor>.<ext>" — the script checked a repo-root-relative
    # path while its CWD was still ext/yeptris_native, and the windows
    # block asked for a .dll mkmf never emits (its windows bundle is
    # .so, DLEXT). The pipeline's name derivations (extconf target,
    # script stage path, loader feature) must agree, the script's CWD
    # must be the repo root before its existence checks, and the ext
    # must export Init_native_<minor> for every minor a leg can name.

    let(:extconf) { File.read(File.expand_path("../ext/yeptris_native/extconf.rb", __dir__)) }
    let(:script) { File.read(File.expand_path("../scripts/build-platform-gem.sh", __dir__)) }
    let(:ext_src) { File.read(File.expand_path("../ext/yeptris_native/yeptris_native.c", __dir__)) }
    let(:supported_minors) { File.read(File.expand_path("../SUPPORTED_MINORS", __dir__)).split }

    it "derives the extconf target minor exactly like NativeLayout" do
      # mkmf's target name IS the staged file name and the Init_ symbol
      expect(extconf).to include('minor = RUBY_VERSION[/\A\d+\.\d+/].tr(".", "_")')
      expect(extconf).to include('create_makefile("yeptris/native_#{minor}")')
      expect(File.read(File.expand_path("../lib/yeptris/native_layout.rb", __dir__)))
        .to include('version[/\A\d+\.\d+/].tr(".", "_")')
    end

    it "stages the bundle flat at lib/yeptris/ (contract clause 2)" do
      expect(script).to include('cp "ext/yeptris_native/$EXT" "lib/yeptris/$EXT"')
    end

    it "checks the ext bundle from the repo root (cd BEFORE the existence gate)" do
      group_i = script.index("::group::Stage and build the platform gem")
      gate_i = script.index("ERROR: no ext bundle", group_i)
      cd_i = script.index('cd "$WORK/yeptris-ruby"', group_i)
      expect(gate_i).to be > group_i
      expect(cd_i).to be > group_i
      expect(cd_i).to be < gate_i
    end

    it "stages the windows bundle under the mkmf-emitted name (no hardcoded .dll)" do
      expect(script).not_to include('BUNDLE="native_${MINOR_US}.dll"')
      expect(script).to include('BUNDLE="$ARTIFACT"')
    end

    it "exports Init_native_<minor> for every SUPPORTED_MINORS member" do
      supported_minors.each do |m|
        m_us = m.tr(".", "_")
        expect(ext_src).to include("void Init_native_#{m_us}(void) { Init_native(); }")
      end
    end

    it "exports the windows mingw 3.0 leg's Init_native_3_0" do
      # mkmf generates the leg's .def from the target name; an export
      # the object does not define is an ld error ("cannot export
      # Init_native_3_0: symbol not defined")
      expect(ext_src).to include("void Init_native_3_0(void) { Init_native(); }")
    end
  end

  describe "no unversioned fallback, ever" do
    it "never requires the unversioned yeptris/native feature" do
      # violation case: a version-agnostic native.so loads under ANY
      # Ruby and is a wrong-ABI gamble across minors (the compiled-in
      # RString layout changed in 3.2 — the 3.1 segfault class; the
      # JSON-parse failure Ruby 3.0 hit under a 3.3-built ext)
      src = File.read(File.expand_path("../lib/yeptris.rb", __dir__))
      expect(src).not_to match(/require\s+["']yeptris\/native["']/)
    end

    it "stages nothing under the old per-minor DIRECTORY layout" do
      # the contract migrates <minor>/native.so subdirs away; the
      # canonical shape is the flat DOT-FREE file
      old = File.expand_path("../lib/yeptris/#{RUBY_VERSION[/\A\d+\.\d+/]}", __dir__)
      expect(File.exist?(old)).to be(false)
    end
  end
end
