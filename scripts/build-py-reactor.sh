#!/usr/bin/env bash
# Build the CPython reactor the benchmark runs (bench/reactor_bench.erl):
# CPython for wasm32-wasip1 linked with bench/py_reactor, an init()/handle()
# reactor with the `_hornbeam` capability module. The sources are
# hornbeam's (wasm/py_reactor) and erlang_wasm's reactor shim.
#
#   WASI_SDK=/path/to/wasi-sdk scripts/build-py-reactor.sh
#
# Writes _build/py-reactor/dist/py_reactor.wasm and py_reactor_lib. The
# first run builds CPython, about twenty minutes; the CPython build needs a
# `wasmtime` CLI on the path to run its build-time Python.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/bench/py_reactor"
TAG="${CPYTHON_TAG:-v3.14.7}"
XY="${CPYTHON_XY:-3.14}"
WASI_SDK="${WASI_SDK:?set WASI_SDK to a WASI SDK directory}"

[ -x "$WASI_SDK/bin/clang" ] || { echo "no WASI SDK at $WASI_SDK" >&2; exit 1; }

WORK="$ROOT/_build/py-reactor"
DEST="$WORK/dist"
mkdir -p "$WORK" "$DEST"

if [ ! -d "$WORK/cpython" ]; then
    echo "cloning CPython $TAG"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$TAG" \
        https://github.com/python/cpython.git "$WORK/cpython"
fi

B="$WORK/cpython/cross-build/wasm32-wasip1"
if [ ! -f "$B/libpython$XY.a" ]; then
    echo "building CPython for wasm32-wasip1 (this takes a while)"
    (cd "$WORK/cpython" && WASI_SDK_PATH="$WASI_SDK" \
        python3 Tools/wasm/wasi build >"$WORK/build.log" 2>&1) || {
        tail -50 "$WORK/build.log" >&2
        echo "CPython build failed; see $WORK/build.log" >&2
        exit 1
    }
fi

echo "compiling the reactor"
for src in "$SRC/worker_reactor.c" "$SRC/hornbeam_caps.c"; do
    (cd "$B" && "$WASI_SDK/bin/clang" -c -O2 -Wall \
        -I. -IInclude -I../../Include -o "$(basename "$src" .c).o" "$src")
done

# The Makefile's own link line for python.wasm, with the command's entry
# point swapped for the reactor objects. `-W' makes make print it even when
# python.wasm is up to date.
echo "linking"
(cd "$B" && make -n -W Programs/python.o python.wasm 2>/dev/null | tail -1 \
    | sed 's| Programs/python.o | worker_reactor.o hornbeam_caps.o |' \
    | sed 's|-o python.wasm|-mexec-model=reactor -o py_reactor.wasm|' \
    | sh)
cp "$B/py_reactor.wasm" "$DEST/py_reactor.wasm"

echo "staging the standard library"
PYLIB="$DEST/py_reactor_lib"
rm -rf "$PYLIB" "$WORK/install"
mkdir -p "$PYLIB"
(cd "$B" && make install DESTDIR="$WORK/install" >/dev/null 2>&1) || true
cp -R "$WORK/install/usr/local/lib/python$XY" "$PYLIB/"
(cd "$PYLIB/python$XY" && rm -rf test idlelib tkinter turtledemo pydoc_data \
    ensurepip site-packages "config-$XY-wasm32-wasi" || true)
find "$PYLIB" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$PYLIB" -name tests -type d -prune -exec rm -rf {} + 2>/dev/null || true

echo "built $DEST/py_reactor.wasm ($(wc -c <"$DEST/py_reactor.wasm") bytes)"
