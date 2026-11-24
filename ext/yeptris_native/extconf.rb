# frozen_string_literal: true

# Builds the native JSON/CBOR materializer (yeptris-ruby#311): the
# per-minor prebuilt bundle loads FIRST ("lib/yeptris/<minor>/native")
# and THIS build is the fallback slot ("require 'yeptris/native'") —
# compiled by the installing Ruby, so it is ABI-correct on every
# minor, present and future. Installs must NEVER fail: any miss (no
# engine binary, no headers, no usable toolchain) degrades to a no-op
# Makefile and the FFI ladder carries the load, exactly as today.

require "mkmf"
require "fileutils"

gem_root = File.expand_path("../..", __dir__)
vendored = File.join(gem_root, "vendor", "libyeptris")

def write_dummy_makefile(reason)
  File.write("Makefile", <<~MAKE)
    all:
    \t@echo "#{reason}"
    install:
    clean:
  MAKE
end

# 1. The engine binary to LINK. Order: CI/dev explicit, then the gem
# root — platform gems vendor the prebuilt lib there, and the pure
# gem's ext/libyeptris extconf builds it there BEFORE this extension
# runs (rubygems builds extensions in gemspec order).
lib = ENV["YEPTRIS_LIB_PATH"]
lib = nil unless lib && File.file?(lib)
lib ||= ["libyeptris.so", "libyeptris.dylib", "yeptris.dll"]
        .map { |n| File.join(gem_root, n) }
        .find { |f| File.exist?(f) }

# 2. The engine headers: CI/dev checkout, then the vendored tree that
# rides every gem artifact (the packaging doctrine's recompile half).
src_roots = [ENV["YEPTRIS_SRC"]].compact
src_roots << File.join(vendored, "src")
src_root = src_roots.find { |d| d && File.directory?(File.join(d, "include")) }

# 0. The toolchain probe — the docstring's third miss (yeptris-ruby#317):
# a toolchain-free image (the alpine musl smoke has no compiler) must
# degrade to the no-op Makefile, not abort inside mkmf's sanity link.
if !have_devel?
  write_dummy_makefile("yeptris: no usable toolchain for the materializer; the FFI ladder carries the load")
elsif lib.nil?
  write_dummy_makefile("yeptris: no libyeptris binary for the materializer; the FFI ladder carries the load")
elsif src_root.nil?
  write_dummy_makefile("yeptris: no engine headers for the materializer; the FFI ladder carries the load")
else
  $INCFLAGS << " -I#{src_root}/include -I#{src_root}/yeptris"
  %w[build-validate/generated build/generated].each do |g|
    d = File.join(File.dirname(src_root), g)
    $INCFLAGS << " -I#{d}" if File.directory?(d)
  end
  # the generated version.h: nothing in the materializer's include
  # chain needs it today; generate it into the workdir so a future
  # include cannot break installs (the vendored tree ships only .in)
  vhin = File.join(src_root, "include", "yeptris", "version.h.in")
  unless File.exist?(File.join(src_root, "include", "yeptris", "version.h"))
    if File.exist?(vhin)
      # CMakeLists sits at the engine tree's root: the vendored gem
      # tree (vendor/libyeptris) or the CI checkout (libyeptris-src).
      # encoding: pinned UTF-8 — the engine sources carry UTF-8 prose
      # (em-dashes in comments), and a POSIX/C-locale environment
      # (debian distro ruby, LC_ALL=C users building the source gem)
      # defaults Ruby's external encoding to US-ASCII, where any byte
      # >= 0x80 makes this regex raise "invalid byte sequence"
      # (surfaced by the riscv64-linux platform-gem leg).
      ver = File.read(File.join(File.dirname(src_root), "CMakeLists.txt"), encoding: "UTF-8")[/project\s*\([^)]*?VERSION\s+([0-9.]+)/m, 1] || "0.0.0"
      maj, min, pat = ver.split(".")
      File.write("version.h", File.read(vhin, encoding: "UTF-8")
        .gsub("@PROJECT_VERSION_MAJOR@", maj || "0")
        .gsub("@PROJECT_VERSION_MINOR@", min || "0")
        .gsub("@PROJECT_VERSION_PATCH@", pat || "0")
        .gsub("@PROJECT_VERSION@", ver))
      $INCFLAGS << " -I."
    end
  end

  libdir = File.dirname(lib)
  $LIBPATH << libdir
  # the bundle must find libyeptris at require time; the gem root is
  # stable within an installation
  $LDFLAGS << " -Wl,-rpath,#{libdir}" if RUBY_PLATFORM =~ /linux|darwin/

  if have_library("yeptris", "yep_json_string") && have_library("yeptris", "yeptris_visit_json")
    # Windows resolves DLL dependencies beside the loading module —
    # install the dll beside the built bundle
    if RUBY_PLATFORM =~ /mswin|mingw/ && File.dirname(lib) != gem_root
      ($INSTALLFILES ||= []) << [lib, "$(RUBYARCHDIR)/yeptris"]
    end
    $CFLAGS << " -O3 -fvisibility=hidden" unless RUBY_PLATFORM =~ /mswin|mingw/
    # The per-minor DOT-FREE artifact (the org native-layer contract,
    # leptris-ruby#671 / yeptris-ruby#409): a source install must
    # produce the per-minor name itself — the loader requires
    # yeptris/native_<major>_<minor> and deliberately has NO
    # unversioned fallback (loading a bundle built by another minor is
    # the wrong-ABI 3.1 segfault class). MRI derives Init_native_<maj>_<min>
    # from the same basename — exported by yeptris_native.c and pinned
    # in the Windows .def below.
    minor_us = RUBY_VERSION[/\A\d+\.\d+/].tr(".", "_")
    if RUBY_PLATFORM =~ /mswin|mingw/
      # PE DLLs export only what a .def or dllexport names (yeptris_native.c
      # dllexports the entry points; the explicit .def keeps the table
      # certain when the toolchain's auto-generated def would win with
      # the wrong list — the leptris-ruby #227 shape).
      def_path = File.expand_path("native_exports.def", __dir__)
      File.write(def_path, <<~DEF)
        EXPORTS
        Init_native
        Init_native_3_3
        Init_native_3_4
        Init_native_4_0
      DEF
      win_def = " #{def_path.tr('/', '\\\\')}"
      $DLDFLAGS << win_def unless $DLDFLAGS.include?("native_exports.def")
    end
    create_makefile("yeptris/native_#{minor_us}")
  else
    write_dummy_makefile("yeptris: materializer link probe failed; the FFI ladder carries the load")
  end
end
