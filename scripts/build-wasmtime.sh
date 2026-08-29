#!/bin/sh
# Build the Wasmtime C API from source.
#
#   scripts/build-wasmtime.sh full|runtime PREFIX
#
# Used by fetch-wasmtime.sh when no prebuilt archive exists for the platform
# (or WASMTIME_SOURCE_BUILD=1 asks for it), and by the release workflow that
# produces the archives. One recipe, so a fallback build and a published
# archive are the same thing.
#
#   full      Wasmtime's default feature set: compiler, WAT, WASI, GC, ...
#   runtime   no compiler, no WAT: wasi, async, gc, gc-drc, threads,
#             pooling-allocator, disable-logging, built with Wasmtime's own
#             size flags (opt-level s, LTO, one codegen unit, panic abort).
#             Only the shared library is kept: linked statically its LTO
#             objects make an 8 MB NIF, dynamically the total is 4 MB.
#             The feature set must keep the engine settings a full build
#             records in a precompiled module (gc, threads, async) so the
#             two accept the same .cwasm files.
#
# Needs git, cmake and cargo. The source tree is cloned next to PREFIX and
# reused. Prints PREFIX on success.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/scripts/wasmtime.version")"
VARIANT="${1:?variant: full or runtime}"
PREFIX="${2:?install prefix}"

for tool in git cmake cargo; do
    command -v "$tool" >/dev/null || {
        echo "wasmtime: no prebuilt library for this platform and '$tool' is missing." >&2
        echo "  Install git, cmake and a Rust toolchain (https://rustup.rs) to build it," >&2
        echo "  or point WASMTIME_C_API_DIR at a directory holding include/ and lib/." >&2
        exit 1
    }
done

case "$VARIANT" in
    full)
        FEATURES=""
        ;;
    runtime)
        FEATURES="-DWASMTIME_DISABLE_ALL_FEATURES=ON -DWASMTIME_FEATURE_WASI=ON \
-DWASMTIME_FEATURE_ASYNC=ON -DWASMTIME_FEATURE_DISABLE_LOGGING=ON -DWASMTIME_FEATURE_GC=ON \
-DWASMTIME_FEATURE_GC_DRC=ON -DWASMTIME_FEATURE_THREADS=ON -DWASMTIME_FEATURE_POOLING_ALLOCATOR=ON"
        export CARGO_PROFILE_RELEASE_OPT_LEVEL=s
        export CARGO_PROFILE_RELEASE_LTO=true
        export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
        export CARGO_PROFILE_RELEASE_PANIC=abort
        ;;
    *) echo "wasmtime: unknown variant '$VARIANT' (full or runtime)" >&2; exit 1 ;;
esac
export CARGO_PROFILE_RELEASE_STRIP=debuginfo

WORK="$(dirname "$PREFIX")"
SRC="$WORK/wasmtime-src"
BUILD="$WORK/build-$VARIANT"
mkdir -p "$WORK"

if [ ! -f "$SRC/crates/c-api/CMakeLists.txt" ]; then
    echo "wasmtime: cloning wasmtime $VERSION" >&2
    rm -rf "$SRC"
    git clone -q --depth 1 --branch "$VERSION" https://github.com/bytecodealliance/wasmtime "$SRC"
fi

echo "wasmtime: building the $VARIANT C API from source (this takes a few minutes)" >&2
rm -rf "$BUILD" "$PREFIX"
# shellcheck disable=SC2086 # FEATURES is a list of -D flags on purpose
cmake -S "$SRC/crates/c-api" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX="$PREFIX" $FEATURES >"$BUILD.log" 2>&1 ||
    { tail -20 "$BUILD.log" >&2; exit 1; }
cmake --build "$BUILD" >>"$BUILD.log" 2>&1 || { tail -20 "$BUILD.log" >&2; exit 1; }
cmake --install "$BUILD" >>"$BUILD.log" 2>&1 || { tail -20 "$BUILD.log" >&2; exit 1; }
[ -f "$PREFIX/include/wasmtime.h" ] || { echo "wasmtime: build produced no headers" >&2; exit 1; }
[ "$VARIANT" = runtime ] && rm -f "$PREFIX/lib/libwasmtime.a"
echo "$PREFIX"
