#!/bin/sh
# Build priv/wasmtime_nif.so, linking the Wasmtime C API statically.
#
# Runs as a rebar3 pre_hook. Unlike an optional NIF, this one is the product,
# so any failure fails the build.
#
# The library may be a full build, a runtime-only build or anything a user
# points WASMTIME_C_API_DIR at. What it can do is probed from the archive
# and passed to the C as NIF_HAVE_COMPILER / NIF_HAVE_WAT / NIF_HAVE_WASI;
# the NIF returns {error, #{kind => unavailable}} for the rest.
#
# Set WASMTIME_NIF_SANITIZE=address (or thread) to build under a sanitizer.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRCDIR="$ROOT/c_src"
OUT="$ROOT/priv/wasmtime_nif.so"
STAMP="$ROOT/_build/wasmtime_nif.stamp"

command -v erl >/dev/null || { echo "wasmtime: erl not found" >&2; exit 1; }
ERTS="$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')"
INC="$(find "$ERTS" -maxdepth 2 -type d -name include -path '*/erts-*' | head -1)"
[ -n "$INC" ] || { echo "wasmtime: erts include dir not found under $ERTS" >&2; exit 1; }

CC="${CC:-cc}"
command -v "$CC" >/dev/null || { echo "wasmtime: C compiler '$CC' not found" >&2; exit 1; }

API="$("$ROOT/scripts/fetch-wasmtime.sh")"
CONF="$API/include/wasmtime/conf.h"

case "$(uname -s)" in
    Darwin)  LDFLAGS="-dynamiclib -undefined dynamic_lookup -Wl,-dead_strip" ;;
    FreeBSD) LDFLAGS="-shared -Wl,--gc-sections -lm -lpthread" ;;
    *)       LDFLAGS="-shared -Wl,--gc-sections -lm -lpthread -ldl" ;;
esac

# Static when the archive is there (the upstream tarball, a full source
# build). Otherwise the shared library: it is copied next to the NIF in
# priv/ and found through an rpath relative to the NIF, so a release carries
# it. The runtime-only archives ship only the shared library: linked
# statically its LTO objects give an 8 MB NIF, dynamically 4 MB in total.
SHARED=""
if [ -f "$API/lib/libwasmtime.a" ]; then
    LIBFILE="$API/lib/libwasmtime.a"
    LIB="$LIBFILE"
else
    LIBFILE="$(find "$API/lib" -maxdepth 1 \( -name libwasmtime.so -o -name libwasmtime.dylib \) | head -1)"
    [ -n "$LIBFILE" ] || { echo "wasmtime: no libwasmtime in $API/lib" >&2; exit 1; }
    SHARED="$LIBFILE"
    # shellcheck disable=SC2016 # the loader expands $ORIGIN, not the shell
    case "$(uname -s)" in
        Darwin) RPATH="@loader_path" ;;
        *)      RPATH='$ORIGIN' ;;
    esac
    LIB="-L$ROOT/priv -lwasmtime -Wl,-rpath,$RPATH"
fi

# Does the library define a symbol? nm handles archives and shared objects;
# without nm, a link test against the library answers the same question.
has_sym() {
    if command -v nm >/dev/null; then
        nm -g "$LIBFILE" 2>/dev/null | grep -Eq " T _?$1\$"
    else
        mkdir -p "$ROOT/_build"
        printf 'extern void %s(void);\nint main(void) { %s(); return 0; }\n' "$1" "$1" > "$ROOT/_build/probe.c"
        # shellcheck disable=SC2086
        "$CC" -o "$ROOT/_build/probe" "$ROOT/_build/probe.c" $LIB -lm -lpthread >/dev/null 2>&1
    fi
}
# Do the headers declare it? A mismatch means headers and library come from
# different builds: stop before an obscure compile or link error.
has_macro() { grep -Eq "^#define ($1)\$" "$CONF"; }
capability() {
    # $1 name, $2 symbol, $3 conf.h macro regex
    if has_sym "$2"; then sym=1; else sym=0; fi
    if has_macro "$3"; then mac=1; else mac=0; fi
    if [ "$sym" != "$mac" ]; then
        echo "wasmtime: $LIBFILE and $CONF disagree about $1 (library: $sym, headers: $mac)" >&2
        echo "  include/ and lib/ must come from the same Wasmtime build" >&2
        exit 1
    fi
    echo "$sym"
}
HAVE_COMPILER="$(capability compiler wasmtime_module_new 'WASMTIME_FEATURE_CRANELIFT|WASMTIME_FEATURE_WINCH')"
HAVE_WAT="$(capability wat wasmtime_wat2wasm 'WASMTIME_FEATURE_WAT')"
HAVE_WASI="$(capability wasi wasmtime_linker_define_wasi 'WASMTIME_FEATURE_WASI')"
FEATURE_FLAGS="-DNIF_HAVE_COMPILER=$HAVE_COMPILER -DNIF_HAVE_WAT=$HAVE_WAT -DNIF_HAVE_WASI=$HAVE_WASI"

CFLAGS="-O2 -g -fPIC -fvisibility=hidden -Wall -Wextra -Wno-unused-parameter -std=c11 -I$INC -I$API/include $FEATURE_FLAGS"
if [ -n "${WASMTIME_NIF_SANITIZE:-}" ]; then
    CFLAGS="$CFLAGS -fsanitize=${WASMTIME_NIF_SANITIZE} -fno-omit-frame-pointer -O1"
fi

# Up to date when the sources are older than the .so and the same library
# and flags were used last time (the stamp).
WANT="$LIBFILE $CFLAGS"
if [ -f "$OUT" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$WANT" ] &&
   [ -z "$(find "$SRCDIR" "$0" -newer "$OUT")" ]; then
    exit 0
fi

mkdir -p "$ROOT/priv" "$ROOT/_build"
# The platform name, so wasmtime.erl finds the precompiled stdin shim for
# it in priv/shims on a runtime-only build.
"$ROOT/scripts/fetch-wasmtime.sh" --platform > "$ROOT/priv/wasmtime_platform"
rm -f "$ROOT/priv/libwasmtime.so" "$ROOT/priv/libwasmtime.dylib"
[ -n "$SHARED" ] && cp "$SHARED" "$ROOT/priv/"
echo "wasmtime: building $OUT (compiler=$HAVE_COMPILER wat=$HAVE_WAT wasi=$HAVE_WASI)" >&2
[ -n "${WASMTIME_NIF_SANITIZE:-}" ] && echo "wasmtime: NIF instrumented with ${WASMTIME_NIF_SANITIZE}" >&2
# shellcheck disable=SC2086 # CFLAGS, LIB and LDFLAGS are word lists on purpose
"$CC" $CFLAGS -o "$OUT" "$SRCDIR"/nif_*.c $LIB $LDFLAGS
echo "$WANT" > "$STAMP"
