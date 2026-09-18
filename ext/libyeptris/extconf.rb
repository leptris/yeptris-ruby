# frozen_string_literal: true

# Builds the vendored libyeptris at gem-install time so EVERY install
# carries the engine (the pure `ruby`-platform gem has no prebuilt
# binary). Platform gems vendor the prebuilt lib at the gem root —
# when one is present this extension no-ops.

require "mkmf"
require "fileutils"

gem_root = File.expand_path("../..", __dir__)
vendored = File.join(gem_root, "vendor", "libyeptris")

prebuilt = ["libyeptris.so", "libyeptris.dylib", "libyeptris.dll",
            "yeptris.dll"].any? { |n| File.exist?(File.join(gem_root, n)) }

def write_dummy_makefile(reason)
  File.write("Makefile", <<~MAKE)
    all:
    \t@echo "#{reason}"
    install:
    clean:
  MAKE
end

if prebuilt
  write_dummy_makefile("yeptris: prebuilt libyeptris ships in this gem; source build skipped")
elsif !File.directory?(vendored)
  write_dummy_makefile("yeptris: no vendored libyeptris sources; set YEPTRIS_LIB_PATH at require time")
elsif find_executable("cmake").nil?
  write_dummy_makefile("yeptris: cmake not found; set YEPTRIS_LIB_PATH at require time")
else
  # Out-of-source into the ext workdir; the shared lib then moves to
  # the GEM ROOT, where ffi.rb's ladder probes it.
  build = File.join(Dir.pwd, "libyeptris-build")
  # BUILD_TESTING (the CMake standard) gates test/ — the vendored
  # tree ships no test dir; the static target must build because the
  # unconditional install(TARGETS yeptris_static) expects it
  args = [
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_TESTING=OFF",
    "-DYEPTRIS_BUILD_CLI=OFF",
    "-DYEPTRIS_BUILD_BENCHMARKS=OFF",
    "-DYEPTRIS_BUILD_SHARED=ON",
  ]
  ok = system("cmake", "-S", vendored, "-B", build, *args) &&
       system("cmake", "--build", build, "--config", "Release")
  lib = Dir.glob(File.join(build, "**", "libyeptris.{so,dylib}")).first
  if ok && lib
    FileUtils.cp(lib, File.join(gem_root, File.basename(lib)))
    write_dummy_makefile("yeptris: built vendored libyeptris at gem install")
  else
    # a failed build must not abort the install — require-time raises
    # the informative ladder error instead
    write_dummy_makefile("yeptris: libyeptris source build failed; set YEPTRIS_LIB_PATH at require time")
  end
end
