# Changelog

## 0.1.0 (unreleased)

First release.

- Compile modules from binary or text, list imports and exports.
- Instantiate with Erlang-backed host functions, WASI preview 1 with explicit
  capabilities, memory and table caps.
- Call exports with integer, float and v128 values; traps reported by kind.
- Interrupt a call with a timeout or from another process.
- Read and write linear memory from Erlang.
- One OS thread per instance; callers never block inside a NIF.
- Wasmtime 48.0.1, downloaded at build time and linked statically.
