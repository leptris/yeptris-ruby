# frozen_string_literal: true

# Builds the native materializer for the CURRENT Ruby and installs it
# under the per-minor DOT-FREE flat name
# (lib/yeptris/native_<major>_<minor>.<so|bundle|dll>) — the org
# native-layer contract (leptris-ruby#671, yeptris-ruby#409).
#
# The leptris-ruby Windows lesson (#207/#227): a PE DLL cannot
# resolve Ruby imports lazily — it must bind the build Ruby's
# x64-ucrt-rubyNNN.dll. One bundle per supported minor therefore ships
# in the platform gems, and the loader in lib/yeptris.rb picks by
# RUBY_VERSION at require. Ruby 3.3 has no arm64 build: that cell
# ships no artifact and falls back to the FFI ladder (the #217 opt-in
# notice).
#
# The name is DOT-FREE with the minor INSIDE it: ruby derives the
# init symbol from the feature basename cut at the first dot, so
# native_3_4.so resolves Init_native_3_4 (exported by
# yeptris_native.c). The dotted native-3.4.so name asked for the
# untypeable "Init_native-3" (#157) and the old unversioned
# native.<ext> file name was the wrong-ABI gamble the contract
# forbids — no unversioned fallback exists.
#
# Bundles link the same shape build-platform-gem.sh uses — no
# libruby DT_NEEDED (its absolute build-runner path dangles on user
# machines; Ruby API symbols resolve from the host process), and
# darwin links with -undefined dynamic_lookup.
#
# Standalone by design: the release workflow runs this under each
# Ruby minor (3.3/3.4/4.0) with no bundler context.

require "rbconfig"
require "fileutils"

root = File.expand_path("..", __dir__)
ext_dir = File.join(root, "ext", "yeptris_native")
minor = RUBY_VERSION[/\A\d+\.\d+/]
minor_us = minor.tr(".", "_")
windows = RbConfig::CONFIG["host_os"] =~ /mingw|mswin/

Dir.chdir(ext_dir) do
  system(RbConfig.ruby, "extconf.rb") or abort "extconf failed under #{RUBY_VERSION}"
  # mkmf's link binds the CURRENT Ruby's runtime DLL — exactly
  # what the per-minor scheme is for.
  if windows
    success = system("make")
  else
    darwin = RbConfig::CONFIG["host_os"] =~ /darwin/
    dld = darwin ? "-dynamic -bundle -undefined dynamic_lookup" : ""
    success = system("make", "LIBRUBYARG_SHARED=", "LIBRUBYARG_STATIC=",
                     "DLDFLAGS=#{dld}")
  end
  abort "make failed under #{RUBY_VERSION}" unless success
  so = Dir.glob("native_#{minor_us}.{so,bundle,dll}").first
  abort "native_#{minor_us} bundle not produced under #{RUBY_VERSION} — " \
        "the extconf must name the artifact per minor" unless so
  dest = File.join(root, "lib", "yeptris", so)
  # The artifact must reference only this minor's Ruby DLL.
  imported = `strings #{so} 2>/dev/null`[/[a-z0-9-]*ruby\d{3,}\.dll/i]
  if imported && !imported.include?("ruby#{minor.delete('.')}")
    abort "#{so} imports #{imported} but was built under #{RUBY_VERSION} — refuse to mis-name it"
  end
  FileUtils.cp(so, dest)
  puts "Installed native materializer for Ruby #{minor} -> #{dest} (#{imported || 'no ruby dll string found'})"
end
