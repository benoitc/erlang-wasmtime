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
- `serialize/1` and `deserialize/1` for Wasmtime's precompiled form.
- `read_memory/4`, `write_memory/4`, `memory_size/2` address an exported
  memory by name.
- `host => Pid` routes host calls to a dedicated process; `handle_host_call/2`
  serves them there.
- Worker threads get a 4 MB stack on every platform.
- `call_async/3` and `await/2,3`.
- Fuel metering: `compile/2` with `fuel => true`, `call/4` with `fuel`,
  `fuel_remaining/1`; `validate/1`; `trace` frames on trap errors;
  `global_get/2`, `global_set/3`, `table_size/2`, `table_grow/3`.
- Compile options: `opt_level` and `proposals` in `compile/2` and
  `validate/2`, `deserialize/2` for matching options, `module_options/1`.
  One engine per option set, capped at 32.
- WASI stdio without files: `stdin => {binary, Bytes}`, `stdout`/`stderr =>
  capture` read back with `read_output/1` under an `output_limit`;
  `args`/`env => inherit`.
- Streams: `send/2` and `close/1` feed a running guest; `stdin`, `stdout`,
  `stderr => stream` and the `erlang.send`/`erlang.recv` imports; output
  arrives as `{wasmtime_stream, Ref, Kind, Bytes}` in the `stream` process;
  `inbox_limit`; `ref/1`. Runtime-only builds load the stdin forwarding
  shim precompiled per platform from `priv/shims`.
- Runtime-only builds (`WASMTIME_RUNTIME_ONLY=1`): no compiler, a 4 MB shared
  library; `features/0` reports the linked library's capabilities and
  `compile/1`, `{wat, _}`, `serialize/1` and the `wasi` option answer
  `kind => unavailable` where absent. Automatic source build of the C API
  for platforms without a prebuilt archive. FreeBSD archives published from
  this repository.
