# Changelog

## 0.3.0 (2026-10-02)

Components and WASI 0.2, with erlang_wasm's term mapping: a componentize-py
agent per request in 0.75 ms on an M4 Pro, 1.27 ms on a 4-vCPU x86_64
runner.

- Pools sized for components: `pooling` takes `core_instances`, `memories`
  and `tables` (each `instances` by default); a component instance's store
  allows 100 core instances by default instead of 10.
- `bench/agent_bench.erl`: a componentize-py agent per request, 0.75 ms and
  5,900 requests a second with 14 callers on an M4 Pro.
- Components: `compile/2`, `deserialize/1,2`, `deserialize_file/1,2` and
  `validate/1` take components; `module_kind/1`; `call/3,4` by `Export` or
  `Interface#Function`, answering `{ok, Value}`; every WIT value crosses
  with erlang_wasm's term mapping; host imports keyed `{Interface,
  Function}`, raw funs answering `{ok, [V]}` or erlang_wasm's typed
  `import_fun/2`; resources as integer handles with `drop_resource/2,3`;
  pooling and precompiled components.
- WASI 0.2 for components with a `wasi` option, from the same keys as
  preview 1; `run/1,2`; streamed stdin and stdout; `clocks => monotonic`
  traps the wall clock with `kind => clock_refused`.
- Wasmtime archives revision 4: every archive carries Wasmtime's `LICENSE`
  and `PATCHES.md` with the patches applied; the runtime-only library adds
  the component model (4.2 MB on macOS arm64, from 2.5 MB).
- `stdin => stream` is a pipe Wasmtime reads, filled by a thread per
  instance: the `fd_read` override is gone, streamed stdin works on
  runtime-only builds without a shim, and WASI 0.2 components will read it
  the same way. Stopping a guest (`timeout`, `interrupt/1`, `destroy/1`)
  now ends its stdin, since that is what wakes a blocked read.
- `clocks => monotonic`: a refused clock answers `ENOTCAPABLE` (76) instead
  of `ENOTSUP` (58), the errno erlang_wasm uses.

## 0.2.0 (2026-09-26)

A fresh, pre-initialized CPython per request in about 1.2 ms (M4), 2.2 ms
(x86_64 cloud vCPU).

- `preinit/3`: run a module's init exports once and get a module that
  starts in their state (Wizer's pre-initialization, in Erlang). Init calls
  as a list or a fun; `_initialize` removed when called; `remove_exports`.
  Snapshots are laid out so Wasmtime maps them copy-on-write.
- `allocator => pooling` compile option with `instances`, `max_memory` and
  `keep_resident`. Out-of-range settings are `badarg` and a pool the host
  cannot reserve is `pool_too_large`, where Wasmtime would abort.
- `deserialize_file/1,2`: load a `.cwasm` by mapping it; its memory image is
  then shared copy-on-write on macOS too.
- `destroy/1`: stop an instance and free its store before returning, so a
  pool slot is free at once.
- `wasi => #{clocks => monotonic}`: wall and CPU clocks answer `ENOTSUP`.
- `wat2wasm/1`.
- Instances of a module share a linker and a Wasmtime `InstancePre` per
  import and WASI shape: WASI and host functions are defined once, not per
  instance (CPython: 150 us to 70 us to instantiate on macOS).
- Linux and musl full C API archives are this project's, built with
  `scripts/wasmtime-patches`: a pool slot is reset by restoring only the
  pages the guest wrote (`PAGEMAP_SCAN`), which Wasmtime's C API cannot
  turn on, and the scan no longer stops after 32 dirty regions.
- `timeout` and `interrupt/1` stop the guest at once instead of at the next
  10 ms epoch tick.
- A host call spins briefly for the reply before sleeping: 2.5 us round trip
  when idle, from 6 us.
- `compile_options()` and `module_options/1` carry `allocator` (and
  `pooling`); the engine key the NIF reads has a fourth element.
- `bench/reactor_bench.erl` and `scripts/bench-reactor.sh`: the acceptance
  benchmark with hornbeam's CPython reactor; `docs/preinit.md`,
  `docs/throughput.md`.

## 0.1.1 (2026-08-29)

- Wasmtime archives come from `wasmtime-runtime-<version>-r<revision>`
  releases (`scripts/wasmtime-runtime.rev`); a build recipe change gets a
  new revision instead of replacing pinned assets. Revision 2 rebuilds every
  archive with the recipe this release ships: the FreeBSD full library now
  has LTO and panic abort like Wasmtime's own releases.
- Hex package lists the C header, the precompiled shims and the examples;
  ex_doc covers every guide, the design note, contributing and releasing.

## 0.1.0 (2026-08-29)

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
- A `stream` stdout or stderr reports itself to the guest as a terminal
  (`fd_fdstat_get` shadowed like `fd_read`), so C libraries line-buffer it:
  scripts need no flush and CPython no `-u`.
- `examples/transform`: user-defined event transforms, one QuickJS worker
  per script over streams, with reload, timeouts and memory limits.
- References across the boundary: `funcref`, `externref` and GC values as
  `ref()` terms in calls, host functions, globals and tables; `null` and
  `{i31, N}`; `externref/2`, `externref_data/1`, `call_ref/3,4`,
  `ref_info/1`, `table_get/3`, `table_set/4`, `table_grow/4`,
  `struct_get/2`, `struct_set/3`, `array_len/1`, `array_get/2`,
  `array_set/3`, `gc/1`. A dropped ref is unrooted by its destructor.
- Runtime-only builds (`WASMTIME_RUNTIME_ONLY=1`): no compiler, a 4 MB shared
  library; `features/0` reports the linked library's capabilities and
  `compile/1`, `{wat, _}`, `serialize/1` and the `wasi` option answer
  `kind => unavailable` where absent. Automatic source build of the C API
  for platforms without a prebuilt archive. FreeBSD archives published from
  this repository.
