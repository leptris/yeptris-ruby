# frozen_string_literal: true

# yeptris-ruby#311 — the compile-at-install lane. The per-minor
# prebuilt bundle loads first; the PURE gem's extensions build the
# engine and the materializer at INSTALL time (the "require
# yeptris/native" slot), ABI-correct on the installing Ruby. The
# extconf must NEVER fail the install: every miss degrades to a no-op
# Makefile and the FFI ladder carries the load. PLATFORM gems (#317)
# register NO extension — the prebuilt native.so rides the artifact
# and installs toolchain-free (the #311 no-op assumption was wrong:
# mkmf aborts before the extconf's degrade runs when no compiler
# exists).

require "tmpdir"
require "fileutils"

RSpec.describe "the native materializer's install lane" do
  let(:repo) { File.expand_path("..", __dir__) }
  let(:extconf) { File.join(repo, "ext", "yeptris_native", "extconf.rb") }

  it "builds the materializer on the pure gem shape (the gemspec's extensions)" do
    spec = Gem::Specification.load(File.join(repo, "yeptris.gemspec"))
    expect(spec.extensions).to eq(["ext/libyeptris/extconf.rb", "ext/yeptris_native/extconf.rb"])
  end

  it "registers NO install-time extension on the platform-gem branch (#317)" do
    Dir.mktmpdir do |dir|
      FileUtils.cp(File.join(repo, "yeptris.gemspec"), dir)
      FileUtils.mkdir_p(File.join(dir, "lib", "yeptris"))
      FileUtils.cp(File.join(repo, "lib", "yeptris.rb"), File.join(dir, "lib", "yeptris.rb"))
      FileUtils.touch(File.join(dir, ".yeptris-platform-gem"))
      spec = Gem::Specification.load(File.join(dir, "yeptris.gemspec"))
      expect(spec.extensions).to eq([])
    end
  end

  it "degrades to a no-op Makefile when no engine binary is present" do
    Dir.mktmpdir do |gemroot|
      # a gem-shaped tree, fully synthesized (vendor/ is gitignored —
      # the repo checkout on CI has none): headers vendored, NO
      # libyeptris binary, no YEPTRIS_LIB_PATH — the install must
      # still succeed
      FileUtils.mkdir_p(File.join(gemroot, "vendor", "libyeptris", "src", "include", "yeptris"))
      File.write(File.join(gemroot, "vendor/libyeptris/CMakeLists.txt"),
                 "project(yeptris\n  VERSION 0.0.0\n)\n")
      header = File.join(gemroot, "vendor/libyeptris/src/include/yeptris/version.h.in")
      FileUtils.mkdir_p(File.dirname(header))
      File.write(header, <<~VIN)
        #ifndef YEPTRIS_VERSION_H
        #define YEPTRIS_VERSION_H
        #define YEPTRIS_VERSION_MAJOR @PROJECT_VERSION_MAJOR@
        #endif
        VIN
      ext = File.join(gemroot, "ext", "yeptris_native")
      FileUtils.mkdir_p(ext)
      work = Dir.mktmpdir
      ok = EnvGuard.without_env("YEPTRIS_LIB_PATH", "YEPTRIS_SRC") do
        system(RbConfig.ruby, extconf, chdir: work, out: File::NULL, err: File::NULL)
      end
      expect(ok).to be(true)
      mk = File.read(File.join(work, "Makefile"))
      expect(mk).to include("the FFI ladder carries the load")
    end
  end
end

# a tiny helper namespace at file scope (the describe body class_evals
# at the lexical toplevel — same-named constants collide on Object)
module EnvGuard
  module_function

  def without_env(*keys)
    saved = keys.to_h { |k| [k, ENV[k]] }
    keys.each { |k| ENV.delete(k) }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
