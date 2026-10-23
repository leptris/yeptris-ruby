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

if lib.nil?
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
      ver = File.read(File.join(vendored, "CMakeLists.txt"))[/project\s*\([^)]*?VERSION\s+([0-9.]+)/m, 1] || "0.0.0"
      maj, min, pat = ver.split(".")
      File.write("version.h", File.read(vhin)
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
    create_makefile("yeptris/native")
  else
    write_dummy_makefile("yeptris: materializer link probe failed; the FFI ladder carries the load")
  end
end
