#!/bin/sh
# Resolve the Wasmtime C API to link, downloading or building it as needed.
#
# Prints a directory holding include/ and lib/ on stdout. Resolution order:
#
#   1. WASMTIME_C_API_DIR       use it as is
#   2. a prebuilt archive       upstream's C API tarball for the full library;
#                               this project's releases for the runtime-only
#                               library and for FreeBSD; checksum-verified
#   3. a source build           when the platform has no archive, or the
#                               download does not exist, or
#                               WASMTIME_SOURCE_BUILD=1
#
# The archives (12-16 MB) are not in the hex package: hex caps tarballs at
# 8 MB, so they are fetched once at compile time and cached under
# _build/wasmtime/<version>/. Same approach as wasmtime-py's
# ci/download-wasmtime.py, moved from publish time to build time.
#
# Variants:
#   WASMTIME_RUNTIME_ONLY=1     runtime + WASI, no compiler (this project's
#                               archive, or a source build). Wasmtime's own
#                               min/ build is not used: it lacks WASI and GC,
#                               so it cannot load modules the full build
#                               compiled.
#   (unset)                     full library
#
# Other overrides:
#   WASMTIME_CACHE_DIR          where to store downloads and builds
#                               (default: _build/wasmtime)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/scripts/wasmtime.version")"
CACHE="${WASMTIME_CACHE_DIR:-$ROOT/_build/wasmtime}/$VERSION"
RELEASE_URL="https://github.com/benoitc/erlang-wasmtime/releases/download/wasmtime-runtime-$VERSION"
UPSTREAM_URL="https://github.com/bytecodealliance/wasmtime/releases/download/$VERSION"

if [ -n "${WASMTIME_C_API_DIR:-}" ]; then
    [ -f "$WASMTIME_C_API_DIR/include/wasmtime.h" ] ||
        { echo "wasmtime: WASMTIME_C_API_DIR=$WASMTIME_C_API_DIR has no include/wasmtime.h" >&2; exit 1; }
    echo "$WASMTIME_C_API_DIR"; exit 0
fi

case "${WASMTIME_RUNTIME_ONLY:-}" in
    1|true|yes) VARIANT=runtime ;;
    ""|0|false|no) VARIANT=full ;;
    *) echo "wasmtime: WASMTIME_RUNTIME_ONLY must be 1 or unset" >&2; exit 1 ;;
esac

source_build() {
    "$ROOT/scripts/build-wasmtime.sh" "$1" "$CACHE/source-$1"
}

# Platform: ARCH-OS as the archive names spell it; empty when unknown.
ARCH=""; OS=""
case "$(uname -m)" in
    arm64|aarch64) ARCH=aarch64 ;;
    x86_64|amd64)  ARCH=x86_64 ;;
esac
case "$(uname -s)" in
    Darwin)  OS=macos ;;
    Linux)   if ldd --version 2>&1 | grep -qi musl; then OS=musl; else OS=linux; fi ;;
    FreeBSD) OS=freebsd ;;
esac

# Which archive, from where, checked against which list.
if [ "$VARIANT" = runtime ]; then
    NAME="wasmtime-runtime-$VERSION-$ARCH-$OS"
    URL="$RELEASE_URL/$NAME.tar.xz"
    SUMS="$ROOT/scripts/wasmtime-runtime.sha256"
else
    NAME="wasmtime-$VERSION-$ARCH-$OS-c-api"
    # Wasmtime publishes no FreeBSD archive; this project's releases do.
    if [ "$OS" = freebsd ]; then URL="$RELEASE_URL/$NAME.tar.xz"; else URL="$UPSTREAM_URL/$NAME.tar.xz"; fi
    SUMS="$ROOT/scripts/wasmtime.sha256"
fi
FILE="$NAME.tar.xz"
DEST="$CACHE/$NAME"

if [ "${WASMTIME_SOURCE_BUILD:-}" = 1 ]; then source_build "$VARIANT"; exit 0; fi

if [ -f "$DEST/include/wasmtime.h" ]; then echo "$DEST"; exit 0; fi

EXPECTED=""
[ -n "$ARCH" ] && [ -n "$OS" ] && EXPECTED="$(grep " $FILE\$" "$SUMS" 2>/dev/null | awk '{print $1}' || true)"
if [ -z "$EXPECTED" ]; then
    echo "wasmtime: no prebuilt $VARIANT library for $(uname -s) $(uname -m); building from source" >&2
    source_build "$VARIANT"; exit 0
fi

mkdir -p "$CACHE"
if [ ! -f "$CACHE/$FILE" ]; then
    echo "wasmtime: downloading $URL" >&2
    if ! curl -fsSL --retry 3 -o "$CACHE/$FILE.part" "$URL"; then
        rm -f "$CACHE/$FILE.part"
        echo "wasmtime: $URL is not available; building from source" >&2
        source_build "$VARIANT"; exit 0
    fi
    mv "$CACHE/$FILE.part" "$CACHE/$FILE"
fi

if command -v sha256sum >/dev/null; then ACTUAL="$(sha256sum "$CACHE/$FILE" | awk '{print $1}')"
else ACTUAL="$(shasum -a 256 "$CACHE/$FILE" | awk '{print $1}')"; fi
if [ "$ACTUAL" != "$EXPECTED" ]; then
    # A wrong checksum on an archive that exists is corruption or tampering,
    # never an unsupported platform: no fallback here.
    rm -f "$CACHE/$FILE"
    echo "wasmtime: checksum mismatch for $FILE" >&2
    echo "  expected $EXPECTED" >&2
    echo "  got      $ACTUAL" >&2
    exit 1
fi

tar -xJf "$CACHE/$FILE" -C "$CACHE"
[ -f "$DEST/include/wasmtime.h" ] || { echo "wasmtime: unexpected archive layout in $FILE" >&2; exit 1; }
echo "$DEST"
