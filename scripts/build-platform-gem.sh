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

echo "::group::Build libyeptris v$V"
git clone --quiet --depth 1 --branch "v$V" https://github.com/leptris/yeptris "$WORK/yeptris-c"
cmake -B "$WORK/yeptris-c/build" -S "$WORK/yeptris-c" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DYEPTRIS_BUILD_TESTING=OFF \
  -DYEPTRIS_BUILD_CLI=OFF -DYEPTRIS_BUILD_SHARED=ON
cmake --build "$WORK/yeptris-c/build"
LIB="$WORK/yeptris-c/build/src/libyeptris.so"
[ -f "$LIB" ] || LIB="$WORK/yeptris-c/build/src/libyeptris.dylib"
echo "lib: $LIB"
echo "::endgroup::"

echo "::group::Build the extension (relative rpath)"
git clone --quiet "$RUBY_REPO" "$WORK/yeptris-ruby"
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
if uname -s | grep -q Darwin; then
  RPATH='@loader_path/..'
else
  RPATH='$ORIGIN/..'
fi
cd ext/yeptris_native
# Distribution link shape (the precompiled-gem standard): NO libruby
# DT_NEEDED entry (its absolute build-runner path dangles on user
# machines) - Ruby API symbols resolve from the host ruby process at
# dlopen. macOS needs -undefined dynamic_lookup; Linux allows
# undefined by default. Deployment target pinned so runner SDKs newer
# than users' macOS don't set a newer min-OS.
if uname -s | grep -q Darwin; then
  export MACOSX_DEPLOYMENT_TARGET=13.0
  DLD="-dynamic -bundle -undefined dynamic_lookup"
else
  DLD=""
fi
YEPTRIS_LIB_PATH="$LIB" YEPTRIS_SRC="$WORK/yeptris-c/src" \
  YEPTRIS_RPATH="$RPATH" ruby extconf.rb
make LIBRUBYARG_SHARED= LIBRUBYARG_STATIC= DLDFLAGS="$DLD -Wl,-rpath,$RPATH"
otool -L native.bundle 2>/dev/null | grep -q libruby && { echo "ERROR: libruby still referenced"; exit 1; }
ldd native.so 2>/dev/null | grep -q libruby && { echo "ERROR: libruby still referenced"; exit 1; } || true
echo "::endgroup::"

echo "::group::Stage and build the platform gem"
EXT=native.so
[ -f "$EXT" ] || EXT=native.bundle
cd "$WORK/yeptris-ruby"
# ffi.rb vendors at the GEM ROOT (../../ from lib/yeptris)
cp "$LIB" "$(basename "$LIB")"
cp "ext/yeptris_native/$EXT" "lib/yeptris/$EXT"
PLATFORM="$(ruby -e 'print Gem::Platform.local.to_s')"
GEMFILE="$(ruby -e '
  require "rubygems/package"
  spec = Gem::Specification.load("yeptris.gemspec")
  spec.platform = Gem::Platform.local
  (Dir["lib/**/*.{so,dylib,bundle}"] + Dir["*.{so,dylib}"]).each { |f| spec.files << f unless spec.files.include?(f) }
  print Gem::Package.build(spec)
' 2>/dev/null | grep -oE "[A-Za-z0-9._-]+\.gem" | tail -1)"
echo "platform: $PLATFORM"
echo "gem: $GEMFILE"
echo "gempath=$WORK/yeptris-ruby/$GEMFILE" > "$WORK/gempath"
echo "::endgroup::"
