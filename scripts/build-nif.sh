#!/bin/sh
# Build priv/wasmtime_nif.so, linking the Wasmtime C API statically.
#
# Runs as a rebar3 pre_hook. Unlike an optional NIF, this one is the product,
# so any failure fails the build.
#
# Set WASMTIME_NIF_SANITIZE=address (or thread) to build under a sanitizer.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/c_src/wasmtime_nif.c"
OUT="$ROOT/priv/wasmtime_nif.so"
VERSION_FILE="$ROOT/scripts/wasmtime.version"

# Up to date when nothing the NIF depends on is newer than it. A sanitizer
# build is never considered up to date: the flags are not in the timestamp.
if [ -z "${WASMTIME_NIF_SANITIZE:-}" ] && [ -f "$OUT" ] &&
   [ -z "$(find "$SRC" "$VERSION_FILE" "$0" -newer "$OUT")" ]; then
    exit 0
fi

command -v erl >/dev/null || { echo "wasmtime: erl not found" >&2; exit 1; }
ERTS="$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')"
INC="$(find "$ERTS" -maxdepth 2 -type d -name include -path '*/erts-*' | head -1)"
[ -n "$INC" ] || { echo "wasmtime: erts include dir not found under $ERTS" >&2; exit 1; }

CC="${CC:-cc}"
command -v "$CC" >/dev/null || { echo "wasmtime: C compiler '$CC' not found" >&2; exit 1; }

API="$("$ROOT/scripts/fetch-wasmtime.sh")"

CFLAGS="-O2 -g -fPIC -Wall -Wextra -Wno-unused-parameter -std=c11 -I$INC -I$API/include"
if [ -n "${WASMTIME_NIF_SANITIZE:-}" ]; then
    CFLAGS="$CFLAGS -fsanitize=${WASMTIME_NIF_SANITIZE} -fno-omit-frame-pointer -O1"
    echo "wasmtime: NIF instrumented with ${WASMTIME_NIF_SANITIZE}" >&2
fi
case "$(uname -s)" in
    Darwin)  LDFLAGS="-dynamiclib -undefined dynamic_lookup -Wl,-dead_strip" ;;
    FreeBSD) LDFLAGS="-shared -Wl,--gc-sections -lm -lpthread" ;;
    *)       LDFLAGS="-shared -Wl,--gc-sections -lm -lpthread -ldl" ;;
esac

# Static when the archive is there (the upstream tarball, a source build with
# the default CMake options); otherwise the shared library with an rpath.
if [ -f "$API/lib/libwasmtime.a" ]; then
    LIB="$API/lib/libwasmtime.a"
else
    LIB="-L$API/lib -lwasmtime -Wl,-rpath,$API/lib"
    echo "wasmtime: no libwasmtime.a in $API/lib, linking the shared library" >&2
fi

mkdir -p "$ROOT/priv"
echo "wasmtime: building $OUT" >&2
# shellcheck disable=SC2086 # CFLAGS, LIB and LDFLAGS are word lists on purpose
"$CC" $CFLAGS -o "$OUT" "$SRC" $LIB $LDFLAGS
