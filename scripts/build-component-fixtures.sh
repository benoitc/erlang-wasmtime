#!/usr/bin/env bash
# Build the component fixtures whose sources live in this repository
# (test/fixtures/components/<name>) for wasm32-wasip2, into
# test/wasmtime_component_SUITE_data/<name>.component.wasm. Needs rustup's
# wasm32-wasip2 target. The other fixtures there come from erlang_wasm; see
# test/wasmtime_component_SUITE_data/README.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rustup target add wasm32-wasip2 >/dev/null 2>&1 || true
for dir in "$ROOT"/test/fixtures/components/*/; do
    name="$(basename "$dir")"
    (cd "$dir" && cargo build --quiet --release --target wasm32-wasip2)
    cp "$dir/target/wasm32-wasip2/release/$name.wasm" \
        "$ROOT/test/wasmtime_component_SUITE_data/$name.component.wasm"
    echo "$name.component.wasm"
done
