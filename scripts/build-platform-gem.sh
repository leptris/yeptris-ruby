#!/usr/bin/env bash
# build-platform-gem.sh — the platform gem for THIS runner's platform
# (TODO.restructure/28's remainder): the ruby gem + vendored
# libyeptris + the compiled native materializer, linked with a
# RELATIVE rpath so the pair travels together.
#
# Usage: build-platform-gem.sh <version> <ruby-repo-url> [workdir]
set -euo pipefail

V="${1:?version required (X.Y.Z)}"
RUBY_REPO="${2:?ruby repo URL required}"
WORK="${3:-$(mktemp -d)}"

IS_WINDOWS=0
if uname -s | grep -qi 'MINGW\|MSYS\|CYGWIN'; then
  IS_WINDOWS=1
fi

echo "::group::Build libyeptris v$V"
git clone --quiet --depth 1 --branch "v$V" https://github.com/leptris/yeptris "$WORK/yeptris-c"
if [ "$IS_WINDOWS" = "1" ]; then
  # Windows (the leptris-ruby legs): the MSVC generator drops the lib
  # prefix and stages in Release/; the gem vendors it AS
  # libyeptris.dll — the ffi ladder's name.
  cmake -B "$WORK/yeptris-c/build" -S "$WORK/yeptris-c" \
    -DYEPTRIS_BUILD_TESTING=OFF \
    -DYEPTRIS_BUILD_CLI=OFF -DYEPTRIS_BUILD_SHARED=ON
  cmake --build "$WORK/yeptris-c/build" --config Release
  LIB="$WORK/yeptris-c/build/bin/Release/yeptris.dll"
  [ -f "$LIB" ] || LIB="$WORK/yeptris-c/build/src/Release/yeptris.dll"
  [ -f "$LIB" ] || LIB="$WORK/yeptris-c/build/src/yeptris.dll"
  # extconf's libdir glob looks for libyeptris.* — alias the MSVC
  # name beside it (mingw ld links the DLL directly)
  cp "$LIB" "$(dirname "$LIB")/libyeptris.dll"
  # mkmf's Dir[] globs choke on the mixed separators Git-Bash hands
  # over (D:\a/_temp/...) — normalize to pure forward slashes
  LIB=$(cygpath -m "$LIB")
else
  if [ "$(uname -s)" = "Darwin" ]; then
    # Versionless darwin platforms (#125): the gem push stamps a
    # kernel suffix (arm64-darwin-23) from the binaries' minos when
    # it sits in the mapped 11-15 window — and a suffixed platform
    # matches ONLY that exact kernel (Tahoe darwin-25 fell back to
    # the DLL-less pure-ruby gem). minos 26.0 is outside the window,
    # so the gem registers versionless and matches every macOS; the
    # minos field does not gate dlopen (verified: a minos-26 dylib
    # loads and binds on darwin-23 — the same recipe leptris-ruby
    # 1.9.193.3 ships). The REAL floor is the lib's symbol use
    # (libSystem basics, macOS 11-era). Revisit if RubyGems widens
    # the mapping table.
    export MACOSX_DEPLOYMENT_TARGET=26.0
    cmake -B "$WORK/yeptris-c/build" -S "$WORK/yeptris-c" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DYEPTRIS_BUILD_TESTING=OFF \
      -DYEPTRIS_BUILD_CLI=OFF -DYEPTRIS_BUILD_SHARED=ON \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
  else
    cmake -B "$WORK/yeptris-c/build" -S "$WORK/yeptris-c" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DYEPTRIS_BUILD_TESTING=OFF \
      -DYEPTRIS_BUILD_CLI=OFF -DYEPTRIS_BUILD_SHARED=ON
  fi
  cmake --build "$WORK/yeptris-c/build"
  LIB="$WORK/yeptris-c/build/src/libyeptris.so"
  [ -f "$LIB" ] || LIB="$WORK/yeptris-c/build/src/libyeptris.dylib"
fi
echo "lib: $LIB"
echo "::endgroup::"

echo "::group::Build the extension (relative rpath)"
# a pre-seeded checkout (the Windows legs build the per-minor native
# DLLs in it before this script runs) is reused as-is
if [ ! -d "$WORK/yeptris-ruby/.git" ]; then
  git clone --quiet "$RUBY_REPO" "$WORK/yeptris-ruby"
fi
cd "$WORK/yeptris-ruby"
LOCKSTEP="$(git tag | grep -E "^v${V//./\.}\.[0-9]+$" | sort -V | tail -1 || true)"
if [ -n "$LOCKSTEP" ]; then
  git checkout --quiet "$LOCKSTEP"
  echo "gem from $LOCKSTEP"
else
  # no lockstep binding tag yet (the C release fired before the
  # binding's): the republish dispatch after the binding tag lands
  # builds them — a clean skip keeps the release run green
  echo "no lockstep gem tag v$V.* — skipping platform gems (republish after the binding tag lands)"
  exit 0
fi
cd ext/yeptris_native
# Distribution link shape (the precompiled-gem standard): NO libruby
# DT_NEEDED entry (its absolute build-runner path dangles on user
# machines) - Ruby API symbols resolve from the host ruby process at
# dlopen. macOS needs -undefined dynamic_lookup; Linux allows
# undefined by default. Deployment target pinned so runner SDKs newer
# than users' macOS don't set a newer min-OS. Windows (mingw make):
# undefined symbols are allowed; the DLL sits at the gem root where
# the ffi ladder finds it by path, and ext_windows links the import.
if uname -s | grep -q Darwin; then
  export MACOSX_DEPLOYMENT_TARGET=13.0
  DLD="-dynamic -bundle -undefined dynamic_lookup"
  RPATH='@loader_path/..'
  EXTRA="-Wl,-rpath,$RPATH"
elif [ "$IS_WINDOWS" = "1" ]; then
  DLD=""
  EXTRA=""
else
  DLD=""
  RPATH='$ORIGIN/..'
  EXTRA="-Wl,-rpath,$RPATH"
fi
YEPTRIS_LIB_PATH="$LIB" YEPTRIS_SRC="$WORK/yeptris-c/src" \
  YEPTRIS_RPATH="${RPATH:-}" ruby extconf.rb
if [ "$IS_WINDOWS" = "1" ]; then
  # PE has no lazy binding (#207/#227): the bundle LINKS its build
  # Ruby's runtime DLL — the per-minor native-<minor>.so scheme
  # carries the right one per user Ruby; this default binds the
  # packaging Ruby's
  make
else
  make LIBRUBYARG_SHARED= LIBRUBYARG_STATIC= DLDFLAGS="$DLD $EXTRA"
fi
otool -L native.bundle 2>/dev/null | grep -q libruby && { echo "ERROR: libruby still referenced"; exit 1; }
if [ "$IS_WINDOWS" != "1" ]; then
  ldd native.so 2>/dev/null | grep -q libruby && { echo "ERROR: libruby still referenced"; exit 1; } || true
fi
echo "::endgroup::"

if [ "$IS_WINDOWS" = "1" ]; then
  # the per-Ruby-minor native DLLs (the #207/#227 lesson): the
  # workflow builds them under each minor BEFORE this script runs —
  # refuse a Windows gem with none (the loud FFI fallback is per-minor
  # acceptable, never wholesale)
  # the packaging Ruby's own minor rides too (the workflow's
  # per-minor steps cover the OTHERS; this build binds this Ruby's
  # runtime). find, not ls|wc: pipefail aborts the assignment when ls
  # matches nothing (the sixth leg run died at the verify with the
  # gem fully built)
  MINOR=$(ruby -e 'print RUBY_VERSION[/\A\d+\.\d+/]')
  cp native.so ../../lib/yeptris/native-"$MINOR".so
  echo "::group::Verify Windows native DLLs"
  count=$(find ../../lib/yeptris -maxdepth 1 -name 'native-*.so' 2>/dev/null | wc -l)
  if [ "$count" -lt 1 ]; then
    echo "ERROR: no native-<minor>.so staged (expected the workflow's per-minor builds)"
    exit 1
  fi
  echo "native DLLs staged: $count"
  echo "::endgroup::"
fi

echo "::group::Stage and build the platform gem"
EXT=native.so
[ -f "$EXT" ] || EXT=native.bundle
cd "$WORK/yeptris-ruby"
# ffi.rb vendors at the GEM ROOT (../../ from lib/yeptris); on
# Windows the MSVC DLL arrives as yeptris.dll and vendors AS
# libyeptris.dll — the ffi ladder's name
if [ "$IS_WINDOWS" = "1" ]; then
  cp "$LIB" "libyeptris.dll"
else
  cp "$LIB" "$(basename "$LIB")"
fi
cp "ext/yeptris_native/$EXT" "lib/yeptris/$EXT"
# macOS: publish VERSIONLESS (arm64-darwin, no kernel suffix) — the
# -23 form only matched the build runner's exact darwin, so Tahoe
# (darwin-25) and friends fell to the DLL-less pure-ruby gem
# (yeptris-ruby#125). The ABI floor is pinned by the build's
# MACOS_DEPLOYMENT_TARGET, not the platform tag.
PLATFORM="$(ruby -e '
  p = Gem::Platform.local
  p.version = nil if p.os == "darwin"
  print p.to_s
')"
GEMFILE="$(ruby -e '
  require "rubygems/package"
  spec = Gem::Specification.load("yeptris.gemspec")
  spec.platform = Gem::Platform.local
  if spec.platform.os == "darwin"
    spec.platform = Gem::Platform.new([spec.platform.cpu, "darwin"])
  end
  (Dir["lib/**/*.{so,dylib,bundle}"] + Dir["*.{so,dylib,dll}"]).each { |f| spec.files << f unless spec.files.include?(f) }
  print Gem::Package.build(spec)
' 2>/dev/null | grep -oE "[A-Za-z0-9._-]+\.gem" | tail -1)"
echo "platform: $PLATFORM"
echo "gem: $GEMFILE"
echo "gempath=$WORK/yeptris-ruby/$GEMFILE" > "$WORK/gempath"
echo "::endgroup::"
