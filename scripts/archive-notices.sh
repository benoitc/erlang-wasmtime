#!/bin/sh
# Put the notices an archive of a modified Wasmtime must carry into DIR:
# Wasmtime's LICENSE (Apache-2.0 WITH LLVM-exception), and PATCHES.md with
# the patches from scripts/wasmtime-patches that the build applied.
#
#   scripts/archive-notices.sh WASMTIME_SRC DIR
#
# Used by .github/workflows/wasmtime-runtime.yml for every archive.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:?Wasmtime source tree}"
DIR="${2:?archive directory}"
VERSION="$(tr -d '[:space:]' < "$ROOT/scripts/wasmtime.version")"
cp "$SRC/LICENSE" "$DIR/LICENSE"
mkdir -p "$DIR/patches"
{
    echo "# Changes to Wasmtime $VERSION"
    echo
    echo "This library is Wasmtime $VERSION (https://github.com/bytecodealliance/wasmtime),"
    echo "built by erlang_wasmtime (https://github.com/benoitc/erlang-wasmtime) with"
    echo "scripts/build-wasmtime.sh and the patches below, which are included in"
    echo "patches/. Wasmtime's license is in LICENSE."
    echo
    for p in "$ROOT"/scripts/wasmtime-patches/*.patch; do
        [ -f "$p" ] || continue
        cp "$p" "$DIR/patches/"
        echo "- patches/$(basename "$p")"
    done
    echo
    sed -n '/^- `/,$p' "$ROOT/scripts/wasmtime-patches/README.md"
} > "$DIR/PATCHES.md"
