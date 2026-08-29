#!/usr/bin/env bash
# Fetch the pinned Wasmtime C API for this platform.
#
# Prints the directory holding include/ and lib/ on stdout. The release
# tarball (12-16 MB) is not in the hex package: hex caps tarballs at 8 MB, so
# it is downloaded once at compile time, checksum-verified, and cached under
# _build/wasmtime/<version>/. The same approach as wasmtime-py's
# ci/download-wasmtime.py, moved from publish time to build time.
#
# Overrides:
#   WASMTIME_C_API_DIR   use this directory (include/, lib/) and do not download
#   WASMTIME_CACHE_DIR   where to store downloads (default: _build/wasmtime)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/scripts/wasmtime.version")"
SUMS="$ROOT/scripts/wasmtime.sha256"

if [ -n "${WASMTIME_C_API_DIR:-}" ]; then
    [ -f "$WASMTIME_C_API_DIR/include/wasmtime.h" ] ||
        { echo "wasmtime: WASMTIME_C_API_DIR=$WASMTIME_C_API_DIR has no include/wasmtime.h" >&2; exit 1; }
    echo "$WASMTIME_C_API_DIR"; exit 0
fi

case "$(uname -m)" in
    arm64|aarch64) ARCH=aarch64 ;;
    x86_64|amd64)  ARCH=x86_64 ;;
    *) echo "wasmtime: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
case "$(uname -s)" in
    Darwin) OS=macos ;;
    Linux)
        if ldd --version 2>&1 | grep -qi musl; then OS=musl; else OS=linux; fi ;;
    FreeBSD)
        # Wasmtime publishes no FreeBSD C API archive and the wasmtime package
        # ships only the CLI. Build the C API from source (docs/building.md)
        # and point WASMTIME_C_API_DIR at the install prefix.
        echo "wasmtime: no upstream C API archive for FreeBSD; set WASMTIME_C_API_DIR (see docs/building.md)" >&2
        exit 1 ;;
    *) echo "wasmtime: unsupported OS $(uname -s)" >&2; exit 1 ;;
esac

NAME="wasmtime-$VERSION-$ARCH-$OS-c-api"
FILE="$NAME.tar.xz"
CACHE="${WASMTIME_CACHE_DIR:-$ROOT/_build/wasmtime}/$VERSION"
DEST="$CACHE/$NAME"

if [ -f "$DEST/include/wasmtime.h" ]; then echo "$DEST"; exit 0; fi

EXPECTED="$(grep " $FILE\$" "$SUMS" | awk '{print $1}')"
[ -n "$EXPECTED" ] || { echo "wasmtime: no checksum for $FILE in scripts/wasmtime.sha256" >&2; exit 1; }

mkdir -p "$CACHE"
URL="https://github.com/bytecodealliance/wasmtime/releases/download/$VERSION/$FILE"
if [ ! -f "$CACHE/$FILE" ]; then
    echo "wasmtime: downloading $URL" >&2
    curl -fsSL --retry 3 -o "$CACHE/$FILE.part" "$URL"
    mv "$CACHE/$FILE.part" "$CACHE/$FILE"
fi

if command -v sha256sum >/dev/null; then ACTUAL="$(sha256sum "$CACHE/$FILE" | awk '{print $1}')"
else ACTUAL="$(shasum -a 256 "$CACHE/$FILE" | awk '{print $1}')"; fi
if [ "$ACTUAL" != "$EXPECTED" ]; then
    rm -f "$CACHE/$FILE"
    echo "wasmtime: checksum mismatch for $FILE" >&2
    echo "  expected $EXPECTED" >&2
    echo "  got      $ACTUAL" >&2
    exit 1
fi

tar -xJf "$CACHE/$FILE" -C "$CACHE"
[ -f "$DEST/include/wasmtime.h" ] || { echo "wasmtime: unexpected tarball layout" >&2; exit 1; }
echo "$DEST"
