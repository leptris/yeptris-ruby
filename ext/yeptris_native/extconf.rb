# frozen_string_literal: true

# Builds the native JSON/CBOR materializer (yeptris-ruby#311) as the
# per-minor DOT-FREE bundle the loader requires
# (lib/yeptris/native_<major>_<minor>.<ext>; the org native-layer
# contract clause 2). mkmf's target name IS the staged file name and
# the Init_ symbol — native_3_4 resolves Init_native_3_4 — so a pure
# (ruby-platform) gem's install lands the bundle exactly where the
# loader looks, for the installing Ruby, ABI-correct on every minor.
# Installs must NEVER fail: any miss (no engine binary, no headers,
# no usable toolchain) degrades to a no-op Makefile and the FFI
# ladder carries the load, exactly as today.

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

# 1. The engine binary to LINK. Order mirrors the loader's candidate
# list (the org native-layer contract clause 1): CI/dev explicit,
# then the platform gems' vendor tree, then the flat lib/ layout
# (where the pure gem's ext/libyeptris extconf stages its build
# BEFORE this extension runs — rubygems builds extensions in
# gemspec order).
lib = ENV["YEPTRIS_LIB_PATH"]
lib = nil unless lib && File.file?(lib)
if lib.nil?
  vendor_libs = Dir[File.join(gem_root, "lib", "yeptris", "vendor", "*", "libyeptris.*")]
  flat_libs = %w[libyeptris.so libyeptris.dylib libyeptris.dll]
              .map { |n| File.join(gem_root, "lib", n) }
  lib = (vendor_libs + flat_libs).find { |f| File.exist?(f) }
end

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
  # the bundle must find libyeptris at require time; the loader's
  # ffi_lib resolves the engine FIRST (yeptris.rb requires ffi before
  # this bundle), so the image is already mapped under the same
  # soname/install name — the rpath only serves a standalone dlopen
  $LDFLAGS << " -Wl,-rpath,#{libdir}" if RUBY_PLATFORM =~ /linux|darwin/

  if have_library("yeptris", "yep_json_string") && have_library("yeptris", "yeptris_visit_json")
    # Windows resolves DLL dependencies beside the loading module —
    # install the dll beside the built bundle (lib/yeptris/)
    if RUBY_PLATFORM =~ /mswin|mingw/
      ($INSTALLFILES ||= []) << [lib, "$(RUBYARCHDIR)/yeptris"]
    end
    $CFLAGS << " -O3 -fvisibility=hidden" unless RUBY_PLATFORM =~ /mswin|mingw/
    # the DOT-FREE per-minor target (contract clause 2): the file
    # name and the Init_ symbol in one — the loader's feature name
    minor = RUBY_VERSION[/\A\d+\.\d+/].tr(".", "_")
    create_makefile("yeptris/native_#{minor}")
  else
    write_dummy_makefile("yeptris: materializer link probe failed; the FFI ladder carries the load")
  end
end
