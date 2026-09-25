#!/usr/bin/env bash
# The pre-initialized CPython benchmark (bench/reactor_bench.erl).
#
#   scripts/bench-reactor.sh [REACTOR_DIR]
#
# REACTOR_DIR holds py_reactor.wasm and py_reactor_lib, as written by
# scripts/build-py-reactor.sh (the default, _build/py-reactor/dist).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REACTOR="${1:-$ROOT/_build/py-reactor/dist}"
[ -f "$REACTOR/py_reactor.wasm" ] || {
    echo "no py_reactor.wasm in $REACTOR: run scripts/build-py-reactor.sh" >&2
    exit 1
}
cd "$ROOT"
rebar3 compile >&2
mkdir -p _build/bench
erlc -o _build/bench bench/reactor_bench.erl
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
erl -noshell -pa _build/default/lib/erlang_wasmtime/ebin -pa _build/bench \
    -eval "reactor_bench:main([\"$REACTOR\", \"$WORK\"]), halt()."
