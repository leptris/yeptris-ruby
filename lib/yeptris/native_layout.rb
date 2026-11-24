# frozen_string_literal: true

module Yeptris
  # The native layout SSOT (the org native-layer contract,
  # leptris-ruby#671): the vendor-tree dir spellings and the per-minor
  # DOT-FREE bundle naming, in ONE ffi-free file so the loader, the
  # packaging script, and the CI gates consume the same mapping —
  # never a second list (the two-images law extended to layout).
  module NativeLayout
    module_function

    # Dir-name candidates for a RUBY_PLATFORM string, in preference
    # order (glibc before musl — dlopen falls through on musl hosts).
    # These name the cells under lib/yeptris/vendor/<platform>/.
    def vendor_platforms_for(ruby_platform)
      # JVM engines report "x86_64-java" or bare "java" — the OS
      # (and sometimes the arch) is lost. Rebuild cpu-os from
      # RbConfig so the native vendor binaries resolve there too.
      if ruby_platform =~ /java/
        host_os = RbConfig::CONFIG["host_os"].to_s
        if host_os =~ /mingw|mswin|windows/
          return [] # no windows vendor tree; the .dll is gem-local
        end
        cpu = RbConfig::CONFIG["host_cpu"].to_s
        cpu = "aarch64" if cpu.empty?
        # RbConfig says "powerpc64le"; the gem/vendor tier is
        # "ppc64le-linux" (the gem platform spelling).
        cpu = "ppc64le" if cpu == "powerpc64le"
        os = host_os =~ /darwin/ ? "darwin" : "linux"
        ruby_platform = "#{cpu}-#{os}"
      end
      case ruby_platform
      when /arm64.*darwin|aarch64.*darwin/ then %w[arm64-darwin]
      when /x86_64.*darwin/ then %w[x86_64-darwin]
      when /aarch64.*linux/ then %w[aarch64-linux aarch64-linux-musl]
      when /x86_64.*linux/ then %w[x86_64-linux x86_64-linux-musl]
      # 32-bit ARM (armv[567l]: "arm-linux", "armv7l-linux",
      # "armeb-linux", ...). Never matches aarch64 ("aarch" has
      # no "arm" substring).
      when /arm.*linux/ then %w[arm-linux arm-linux-musl]
      # POWER8+ little-endian and IBM Z (qemu-built platform gems)
      when /ppc64le.*linux/ then %w[ppc64le-linux]
      when /s390x.*linux/ then %w[s390x-linux s390x-linux-musl]
      # the trixie distro-ruby leg (no musl ruby image ships the port)
      when /riscv64.*linux/ then %w[riscv64-linux]
      else []
      end
    end

    # The per-minor DOT-FREE bundle feature name (contract clause 2):
    # yeptris/native_<major>_<minor> — MRI derives the init symbol
    # from the feature basename cut at the first dot, so the file name
    # carries no dot (native_3_4.so resolves Init_native_3_4; the old
    # native-<minor>.so name asked for the untypeable "Init_native-3",
    # #157).
    def bundle_feature(version = RUBY_VERSION)
      minor = version[/\A\d+\.\d+/].tr(".", "_")
      "yeptris/native_#{minor}"
    end
  end
end
