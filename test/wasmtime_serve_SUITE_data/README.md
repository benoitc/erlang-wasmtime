# Serving guests

Wasmtime's own test programs (`crates/test-programs` of
[bytecodealliance/wasmtime](https://github.com/bytecodealliance/wasmtime),
Apache-2.0 WITH LLVM-exception), built from the v48.0.1 tag by erlang_wasm's
`scripts/build-wasmtime-p2.sh` and copied from its fixtures, so both runtimes
serve the same guests.

- `p2_cli_serve_*`: `wasi:http/incoming-handler` (WASI 0.2);
- `p3_cli_serve_*` and `p3_http_echo`: `wasi:http/handler` (WASI 0.3).

`wasmtime_serve_SUITE` also uses `httpget` from the component suite as a
component with no handler.
