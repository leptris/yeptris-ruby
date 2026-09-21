#!/bin/sh
# smoke-gem.sh — install the BUILT gem into an isolated GEM_HOME and
# run the binding's artifact battery against the INSTALLED gem
# (TODO.restructure/40). RubyGems push happens only after this passes:
# the 0.1.13.5 train shipped a gem whose native path failed its own
# spec suite; green-on-source proved nothing about the artifact.
#
# Usage: smoke-gem.sh <path/to/yeptris-*.gem> <binding-checkout-dir>
# Env:  YEPTRIS_LIB_PATH — optional; the ruby-platform gem needs it
#       (no vendored lib); platform gems self-locate their vendored
#       lib via the ffi ladder's gem-root path.
set -eu

gem_file="$1"
binding_dir="$2"

if [ ! -f "$binding_dir/scripts/gem-smoke.rb" ]; then
  echo "smoke-gem: $binding_dir has no scripts/gem-smoke.rb" >&2
  echo "  (pre-40 binding tag? the artifact battery is mandatory —" >&2
  echo "   cut a binding tag that carries it before releasing)" >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin) libext=dylib ;;
  *) libext=so ;;
esac

home="$(mktemp -d)"
trap 'rm -rf "$home"' EXIT

ver="$(basename "$gem_file" | sed -E 's/^yeptris-([0-9.]+)(-[a-z0-9_-]+)?\.gem$/\1/')"
if [ -z "$ver" ]; then
  echo "smoke-gem: cannot parse version from $gem_file" >&2
  exit 1
fi

# ffi is a runtime dependency of every gem variant; --local refuses
# to resolve it, so install it into the isolated home first
GEM_HOME="$home" GEM_PATH="$home" gem install ffi --no-document >/dev/null
GEM_HOME="$home" GEM_PATH="$home" gem install --local --ignore-dependencies "$gem_file" >/dev/null

if [ -n "${YEPTRIS_LIB_PATH:-}" ]; then
  export YEPTRIS_LIB_PATH
fi
GEM_HOME="$home" GEM_PATH="$home" ruby "$binding_dir/scripts/gem-smoke.rb" "$ver"
