#!/usr/bin/env bash
# Build the componentize-py agent the component benchmark runs
# (bench/agent, bench/agent_bench.erl) into _build/agent/agent.wasm.
# Installs componentize-py into _build/agent/venv when it is not on the
# path.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/_build/agent"
mkdir -p "$OUT"
CPY="$(command -v componentize-py || true)"
if [ -z "$CPY" ]; then
    [ -x "$OUT/venv/bin/componentize-py" ] || {
        python3 -m venv "$OUT/venv"
        "$OUT/venv/bin/pip" install -q componentize-py
    }
    CPY="$OUT/venv/bin/componentize-py"
fi
cd "$ROOT/bench/agent"
"$CPY" -d wit -w agent componentize app -o "$OUT/agent.wasm"
echo "built $OUT/agent.wasm ($(wc -c <"$OUT/agent.wasm") bytes, $("$CPY" --version))"
