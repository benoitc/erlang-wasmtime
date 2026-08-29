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
- Ownership: Erlang holds a handle, the instance is owned by the handle and by
  its detached worker thread; messages carry an Erlang reference, never a
  resource term. No destructor blocks a scheduler.
- A call `timeout` cancels the request by id; its result is dropped in the
  NIF. A caller that dies has its running call interrupted and its queued
  calls dropped. A host function calling the instance it runs on is refused
  with `kind => reentrant`. Interrupting a guest parked in a host function
  reports `kind => interrupt`.
- Values cross the boundary through the raw C API so `v128` works; the typed
  path aborts the process on it.
