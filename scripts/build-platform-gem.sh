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
# a pre-seeded engine checkout (the workflow's per-minor native
# prebuilds) is reused as-is — but its BUILD DIR carries the prebuild
# step's generator choice (Visual Studio), and configuring here with
# Ninja trips CMake's cache guard. Build dirs are disposable: wipe.
#
# ruby#399: the container legs prebuild the engine ONCE in the shared
# workspace before the per-minor bundle loop, and YEPTRIS_KEEP_
# ENGINE_BUILD=1 makes this run reuse that build dir instead of
# wiping and rebuilding it. The reuse is same-generator by
# construction (the prebuild ran the same Ninja/default line below —
# the VS cache-guard dance is a Windows prebuild, and the Windows
# legs never set the flag), and in qemu emulation an engine build is
# the bulk of a leg's wall clock.
LIB=""
if [ "${YEPTRIS_KEEP_ENGINE_BUILD:-}" = "1" ]; then
  for cand in "$WORK/yeptris-c/build/src/libyeptris.so" \
              "$WORK/yeptris-c/build/src/libyeptris.dylib" \
              "$WORK/yeptris-c/build/bin/Release/yeptris.dll" \
              "$WORK/yeptris-c/build/src/Release/yeptris.dll" \
              "$WORK/yeptris-c/build/src/yeptris.dll"; do
    if [ -f "$cand" ]; then
      LIB="$cand"
      break
    fi
  done
  [ -n "$LIB" ] || echo "YEPTRIS_KEEP_ENGINE_BUILD=1 but no prebuilt engine under $WORK/yeptris-c/build — building it" >&2
fi
if [ -z "$LIB" ]; then
  if [ ! -d "$WORK/yeptris-c/.git" ]; then
    git clone --quiet -c core.autocrlf=false -c core.eol=lf --depth 1 --branch "v$V" https://github.com/leptris/yeptris "$WORK/yeptris-c"
  fi
  rm -rf "$WORK/yeptris-c/build"
  if [ "$IS_WINDOWS" = "1" ] && [ "$(ruby -e 'print Gem::Platform.local.to_s' 2>/dev/null)" = "x64-mingw32" ]; then
  # Ruby <= 3.0 (x64-mingw32, the msvcrt ABI): the RubyInstaller
  # mingw-w64 toolchain — gcc via Ninja; gcc keeps the lib prefix and
  # stages under src/ directly, so the MSVC name dances do not apply
  cmake -B "$WORK/yeptris-c/build" -S "$WORK/yeptris-c" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    -DYEPTRIS_BUILD_CLI=OFF -DYEPTRIS_BUILD_SHARED=ON
  cmake --build "$WORK/yeptris-c/build"
  LIB="$WORK/yeptris-c/build/src/libyeptris.dll"
  [ -f "$LIB" ] || { echo "mingw build produced no libyeptris.dll" >&2; exit 1; }
  # mkmf chokes on the mixed separators Git-Bash hands over
  # (D:\a/_temp/...) — normalize, same as the MSVC branch
  LIB=$(cygpath -m "$LIB")
elif [ "$IS_WINDOWS" = "1" ]; then
  # Windows (the leptris-ruby legs): the MSVC generator drops the lib
  # prefix and stages in Release/; the gem vendors it AS
  # libyeptris.dll — the ffi ladder's name.
  cmake -B "$WORK/yeptris-c/build" -S "$WORK/yeptris-c" \
    -DBUILD_TESTING=OFF \
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
      -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
      -DYEPTRIS_BUILD_CLI=OFF -DYEPTRIS_BUILD_SHARED=ON \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
  else
    cmake -B "$WORK/yeptris-c/build" -S "$WORK/yeptris-c" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
      -DYEPTRIS_BUILD_CLI=OFF -DYEPTRIS_BUILD_SHARED=ON
  fi
  cmake --build "$WORK/yeptris-c/build"
  LIB="$WORK/yeptris-c/build/src/libyeptris.so"
  [ -f "$LIB" ] || LIB="$WORK/yeptris-c/build/src/libyeptris.dylib"
fi
fi
echo "lib: $LIB"
echo "::endgroup::"

echo "::group::Build the extension (relative rpath)"
# a pre-seeded checkout (the Windows legs build the per-minor native
# DLLs in it before this script runs) is reused as-is
if [ ! -d "$WORK/yeptris-ruby/.git" ]; then
  git clone --quiet -c core.autocrlf=false -c core.eol=lf "$RUBY_REPO" "$WORK/yeptris-ruby"
fi
cd "$WORK/yeptris-ruby"
# platform gems vendor the prebuilt lib: they must NOT register the
# source-build extension (toolchain-free installs). The marker must
# sit beside yeptris.gemspec for the gemspec to see it.
touch .yeptris-platform-gem
# the C sources ride the compiled packages too (the distribution
# contract): a prebuilt lib for zero-toolchain installs AND the tree
# for anyone who wants to rebuild against their own toolchain
mkdir -p vendor/libyeptris
cp -R "$WORK/yeptris-c/CMakeLists.txt" "$WORK/yeptris-c/cmake" "$WORK/yeptris-c/src" vendor/libyeptris/ 2>/dev/null || true
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
  RPATH='@loader_path/../../..'
  EXTRA="-Wl,-rpath,$RPATH"
elif [ "$IS_WINDOWS" = "1" ]; then
  DLD=""
  EXTRA=""
else
  DLD=""
  RPATH='$ORIGIN/../../..'
  EXTRA="-Wl,-rpath,$RPATH"
fi
YEPTRIS_LIB_PATH="$LIB" YEPTRIS_SRC="$WORK/yeptris-c/src" \
  YEPTRIS_RPATH="${RPATH:-}" ruby extconf.rb
if [ "$IS_WINDOWS" = "1" ]; then
  # PE has no lazy binding (#207/#227): the bundle LINKS its build
  # Ruby's runtime DLL — the per-minor DOT-FREE scheme carries the
  # right one per user Ruby; this default binds the packaging Ruby's
  make
else
  make LIBRUBYARG_SHARED= LIBRUBYARG_STATIC= DLDFLAGS="$DLD $EXTRA"
fi
# the DOT-FREE per-minor artifact the extconf names (contract clause 2)
MINOR_US=$(ruby -e 'print RUBY_VERSION[/\A\d+\.\d+/].tr(".", "_")')
ARTIFACT=""
for cand in "native_${MINOR_US}.bundle" "native_${MINOR_US}.so" "native_${MINOR_US}.dll"; do
  [ -f "$cand" ] && ARTIFACT="$cand" && break
done
[ -n "$ARTIFACT" ] || { echo "ERROR: extconf produced no native_${MINOR_US} bundle" >&2; exit 1; }
echo "ext artifact: $ARTIFACT"
otool -L "$ARTIFACT" 2>/dev/null | grep -q libruby && { echo "ERROR: libruby still referenced"; exit 1; }
if [ "$IS_WINDOWS" != "1" ]; then
  ldd "$ARTIFACT" 2>/dev/null | grep -q libruby && { echo "ERROR: libruby still referenced"; exit 1; } || true
fi
echo "::endgroup::"

if [ "$IS_WINDOWS" = "1" ]; then
  # the per-Ruby-minor native bundles (the #207/#227 lesson): the
  # workflow builds them under each minor BEFORE this script runs —
  # refuse a Windows gem with none (the loud FFI fallback is per-minor
  # acceptable, never wholesale). DOT-FREE per-minor file names at
  # lib/yeptris/ (native_<major>_<minor>.dll — the org native-layer
  # contract clause 2; MRI derives Init_native_3_4 from the basename
  # cut at the first dot); the packaging Ruby's own minor rides too
  # (the workflow's per-minor steps cover the OTHERS; this build binds
  # this Ruby's runtime). find, not ls|wc: pipefail aborts the
  # assignment when ls matches nothing (the sixth leg run died at the
  # verify with the gem fully built)
  MINOR_US=$(ruby -e 'print RUBY_VERSION[/\A\d+\.\d+/].tr(".", "_")')
  BUNDLE="native_${MINOR_US}.dll"
  [ -f "$BUNDLE" ] || { echo "ERROR: no ext bundle native_${MINOR_US}.dll built" >&2; exit 1; }
  cp "$BUNDLE" "../../lib/yeptris/native_${MINOR_US}.dll"
  echo "::group::Verify Windows native bundles"
  count=$(find ../../lib/yeptris -maxdepth 1 -name 'native_*.*' 2>/dev/null | wc -l)
  if [ "$count" -lt 1 ]; then
    echo "ERROR: no lib/yeptris/native_<minor>.* staged (expected the workflow's per-minor builds)" >&2
    exit 1
  fi
  echo "native bundles staged: $count"
  echo "::endgroup::"
fi

echo "::group::Stage and build the platform gem"
MINOR_US=$(ruby -e 'print RUBY_VERSION[/\A\d+\.\d+/].tr(".", "_")')
EXT="native_${MINOR_US}.so"
[ -f "ext/yeptris_native/$EXT" ] || EXT="native_${MINOR_US}.bundle"
[ -f "ext/yeptris_native/$EXT" ] || { echo "ERROR: no ext bundle $EXT" >&2; exit 1; }
cd "$WORK/yeptris-ruby"
# The org native-layer contract clause 3: platform gems = the vendor
# tree + one bundle per supported minor. The engine binary stages in
# the vendor tree (lib/yeptris/vendor/<platform>/, the loader's
# candidate clause 1.2); on windows there is no vendor tree — the
# DLL is gem-local flat (lib/libyeptris.dll, clause 1.3). The vendor
# dir spelling is the LOADER's mapping (NativeLayout, the SSOT —
# never a second list).
if [ "$IS_WINDOWS" = "1" ]; then
  mkdir -p lib
  cp "$LIB" lib/libyeptris.dll
else
  VENDOR_DIR="$(ruby -Ilib -ryeptris/native_layout -e '
    dirs = Yeptris::NativeLayout.vendor_platforms_for(RUBY_PLATFORM)
    # the build'"'"'s own libc family stages into its OWN dir (the
    # leptris-ruby staging: the musl gem packs the musl dir, gnu the
    # gnu dir) — the loader still probes gnu-before-musl and dlopen
    # falls through on a musl host
    dir = RUBY_PLATFORM.include?("musl") ? (dirs.find { |d| d.include?("musl") } || dirs.first) : dirs.first
    print dir.to_s
  ')"
  [ -n "$VENDOR_DIR" ] || { echo "ERROR: no vendor tree spelling for RUBY_PLATFORM=${RUBY_PLATFORM} (the gem would ship an unreachable binary)" >&2; exit 1; }
  mkdir -p "lib/yeptris/vendor/$VENDOR_DIR"
  cp "$LIB" "lib/yeptris/vendor/$VENDOR_DIR/$(basename "$LIB")"
  echo "vendored engine -> lib/yeptris/vendor/$VENDOR_DIR/$(basename "$LIB")"
fi
if [ "$IS_WINDOWS" = "1" ]; then
  cp "ext/yeptris_native/$EXT" "lib/yeptris/$EXT"
else
  # POSIX stages per-minor DOT-FREE at lib/yeptris/ (contract clause
  # 2): the loader must never run an ext built for a different Ruby
  # minor (3.0 loading the 3.3 build = the JSON ParseError). The
  # file NAME carries the minor (native_3_4.so → Init_native_3_4).
  cp "ext/yeptris_native/$EXT" "lib/yeptris/$EXT"
  # ruby#399 publication contract: the gem tree must carry the
  # complete per-minor bundle set before packaging — a missing minor
  # silently locks that Ruby's hosts onto the FFI ladder (0.6.73.0's
  # musl/arm gems shipped 3.4 only). CI legs set YEPTRIS_REQUIRE_
  # FULL_MINOR_SET=1; an ad-hoc single-minor dev build leaves it unset
  # and keeps the old behavior. YEPTRIS_EXPECTED_MINORS narrows the
  # requirement for floor-limited platforms (s390x 3.2 / riscv64 3.3 —
  # the official images stop there); unset means the full SSOT.
  if [ "${YEPTRIS_REQUIRE_FULL_MINOR_SET:-}" = "1" ]; then
    SSOT="$(cd "$(dirname "$0")/.." && pwd)/SUPPORTED_MINORS"
    expected="${YEPTRIS_EXPECTED_MINORS:-$(cat "$SSOT")}"
    missing=""
    for m in $expected; do
      # DOT-FREE per-minor file name (contract clause 2): 3.4 ->
      # native_3_4.<ext> at lib/yeptris/
      m_us=$(printf '%s' "$m" | tr "." "_")
      [ -f "lib/yeptris/native_${m_us}.${EXT##*.}" ] || missing="$missing $m"
    done
    if [ -n "$missing" ]; then
      echo "ERROR: incomplete per-minor set — missing:$missing (expected lib/yeptris/native_<minor>.${EXT##*.} for:$expected; ruby#399)" >&2
      exit 1
    fi
    echo "per-minor set complete: $expected"
  fi
fi
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
  # the vendor tree (engine binary) + the per-minor bundles ride the
  # lib/** glob — no gem-root binaries (the contract migrated the
  # flat gem-root layout away)
  Dir["lib/**/*.{so,dylib,bundle,dll}"].each { |f| spec.files << f unless spec.files.include?(f) }
  print Gem::Package.build(spec)
' 2>/dev/null | grep -oE "[A-Za-z0-9._-]+\.gem" | tail -1)"
echo "platform: $PLATFORM"
echo "gem: $GEMFILE"
# packaging doctrine (#169): the built gem must carry the prebuilt
# engine AND its build inputs — a failure fails the leg, not just a
# review note
ruby scripts/audit_gem_doctrine.rb "$GEMFILE"
echo "gempath=$WORK/yeptris-ruby/$GEMFILE" > "$WORK/gempath"
echo "::endgroup::"
