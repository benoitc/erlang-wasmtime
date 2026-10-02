#!/usr/bin/env bash
# The componentize-py agent benchmark (bench/agent_bench.erl).
#
#   scripts/bench-agent.sh [AGENT_WASM]
#
# AGENT_WASM defaults to _build/agent/agent.wasm, from scripts/build-agent.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WASM="${1:-$ROOT/_build/agent/agent.wasm}"
[ -f "$WASM" ] || { echo "no $WASM: run scripts/build-agent.sh" >&2; exit 1; }
cd "$ROOT"
rebar3 compile >&2
mkdir -p _build/bench
erlc -o _build/bench bench/agent_bench.erl
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
erl -noshell -pa _build/default/lib/erlang_wasmtime/ebin -pa _build/bench \
    -eval "agent_bench:main([\"$WASM\", \"$WORK\"]), halt()."
