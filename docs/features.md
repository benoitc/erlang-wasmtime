# Features

What is implemented, what is refused explicitly, and what is deferred. When a
feature is missing the runtime says so with an error; it does not approximate.

## Implemented

| Area | Status |
|---|---|
| Compile from binary or `.wat` text | yes, dirty CPU scheduler |
| WebAssembly proposals | Wasmtime 48 defaults, verified by compiling probe modules: bulk memory, reference types, multi-value, SIMD, relaxed SIMD, tail calls, extended const, multi-memory, memory64, exceptions, GC and typed function references, threads and shared memories |
| Instantiate with host functions | yes, function imports only |
| Call exports | yes, `i32`, `i64`, `f32`, `f64`, `v128` values |
| Traps | reported with `class => trap` and a `kind` per Wasmtime trap code |
| Interruption | `timeout` option and `interrupt/1`, epoch based: the epoch is bumped as they fire, so the guest stops at its next loop back-edge or call |
| Memory cap | `memory_limit`, default 256 MB, enforced by the store limiter |
| Table, element and instance caps | `max_tables`, `max_table_elements`, `max_instances` |
| Memory access from Erlang | `read_memory/3,4`, `write_memory/3,4`, `memory_size/1,2`: the export named `memory` (or the first exported memory) by default, any exported memory by name |
| Precompiled modules | `serialize/1` and `deserialize/1`, Wasmtime's `.cwasm` form; `deserialize_file/1,2` maps the file; see [precompiled](precompiled.md) |
| Pre-initialization | `preinit/3`: run init exports once, get a module starting in their state (memories, mutable globals); init calls as a list or a fun; `remove_exports`; see [preinit](preinit.md) |
| Pooling allocator | `allocator => pooling` with `instances`, `max_memory`, `keep_resident`; copy-on-write memory images |
| Explicit teardown | `destroy/1`: stops the instance and frees its store (and pool slot) before returning |
| Text to binary | `wat2wasm/1` |
| Host functions in a dedicated process | `host => Pid` at instantiate, `handle_host_call/2` in that process |
| Non-blocking calls | `call_async/3` and `await/2,3` |
| Fuel metering | `compile(Bin, #{fuel => true})`, `call/4` with `fuel`, `fuel_remaining/1`; `kind => out_of_fuel` |
| Structured traps | `trace` on trap errors: `[#{func_index, func_offset, func_name, module_name}]`, innermost first |
| Validation without compiling | `validate/1`, `validate/2` with options |
| Compile options | `compile/2`: `opt_level` (`none`, `speed`, `speed_and_size`), `proposals` on or off, `fuel`; `module_options/1`; `deserialize/2` to pick the engine |
| Globals and tables from Erlang | `global_get/2`, `global_set/3`, `table_size/2`, `table_get/3`, `table_set/4`, `table_grow/3,4` |
| References across the boundary | `funcref`, `externref` and GC values as `ref()` terms, `null`, `{i31, N}`: in calls, host signatures, globals and tables; `externref/2` wraps a term; `call_ref/3,4`; `struct_get/set`, `array_len/get/set`; `gc/1`; see [references](references.md) |
| WASI stdio in memory | `stdin => {binary, _}`, `stdout`/`stderr => capture` with `read_output/1` and `output_limit`; `args`/`env => inherit` |
| Streams | `send/2`, `close/1`, `inbox_limit`; `stdin`/`stdout`/`stderr => stream` (a streamed stdout looks like a terminal to the guest, so lines leave as written); the `erlang.send` and `erlang.recv` imports; `{wasmtime_stream, Ref, Kind, Bytes}` to the `stream` process; see [streams](streams.md) |
| Runtime-only builds | `WASMTIME_RUNTIME_ONLY=1`: no compiler, 4 MB; `features/0` reports the linked library's capabilities; see [building](building.md) |
| Source build fallback | a platform without a prebuilt archive compiles the C API itself |
| WASI preview 1 | args, env, preopened dirs with read or write, stdio to file or inherited; `clocks => monotonic` refuses wall and CPU clocks with `ENOTCAPABLE` |
| Caller death | the abandoned call is interrupted, queued calls proceed |
| Host function timeout | `host_timeout`, default 30 s |

## Execution model

- One OS thread per instance owns the Wasmtime store. Calls are queued; one runs
  at a time.
- The calling process waits in `receive`; it is never blocked inside a NIF
  while the guest runs, so schedulers are not held.
- Host functions run in the calling process.
- One shared engine compiles every module; instances share nothing else.
- Erlang holds a handle; the instance itself is owned jointly by that handle
  and its thread. Dropping the handle tells the thread to stop and never
  blocks a scheduler. A caller that dies has its running call interrupted and
  its queued calls dropped.
- `timeout` cancels the request by id: its result is dropped in the NIF, so
  nothing lands in the mailbox afterwards. A result that arrived just as the
  timeout fired is returned as the answer.

## Refused explicitly

| Request | Error |
|---|---|
| Import the module does not provide | `class => link` |
| Non-function import from Erlang | `kind => unsupported_import` |
| `exnref` in a call or host signature, or `v128` and references in one signature | `kind => unsupported_type` |
| A reference used with another instance | `kind => wrong_instance` |
| `null` for a non-nullable type, a reference of the wrong family, an `{i31, N}` out of range | `kind => badarg` |
| Memory access while the guest runs | `kind => busy` |
| Memory access on an instance without memory | `kind => no_memory` |
| Out of range memory access | `kind => out_of_bounds` |
| Wrong argument count or type | `kind => badarity`, `kind => badarg` |
| A host function calling the instance it runs on | `kind => reentrant` |
| `compile/1`, `{wat, _}`, `serialize/1` or the `wasi` option on a build without them | `kind => unavailable` |
| `fuel` on a module compiled without metering | `kind => fuel_disabled` |
| A 33rd distinct compile option set | `kind => too_many_configurations` |
| `opt_level` other than `speed`, or a proposal the library lacks, on a build without it | `kind => unavailable` |
| Writing a constant global | `kind => immutable` |
| `send/2` past `inbox_limit`, or after `close/1` | `kind => inbox_full`, `kind => closed` |
| An `imports` entry for `erlang.send` or `erlang.recv` | `kind => reserved_import` |
| `erlang.send` or `erlang.recv` imported with another type | `kind => unsupported_type` |
| `stdin => stream` on a runtime-only build of a platform without a shim in `priv/shims` | `kind => unavailable` |
| Pooling options out of range | `kind => badarg` |
| A pool whose address space the host cannot reserve | `kind => pool_too_large` |
| A module whose memory does not fit a pool slot | `class => compile` |
| One instance more than the pool holds | `class => link` |
| `allocator => pooling` on a build without the pooling allocator | `kind => unavailable` |
| `preinit/3` on a module importing a memory, table or global | `class => preinit, kind => unsupported_import` |
| `preinit/3` on GC types or a mutable reference global | `class => preinit, kind => unsupported_type` |
| `preinit/3` on a shared memory, a component, or a reserved export name | `class => preinit, kind => unsupported` |
| `preinit/3` when an init call changed a table | `class => preinit, kind => table_changed` |
| `preinit/3` on bytes that are not a module | `class => preinit, kind => malformed` |
| A call, or a ref of the instance, after `destroy/1` | `kind => stopped` |

## Deferred

- **Creating GC structs and arrays from Erlang.** Values the guest creates
  can be read and written field by field; creating one needs a type handle
  the C API only gives for an existing value. Exception references
  (`exnref`) are not exposed.
- **Thread pool, or guests on the caller's dirty scheduler.** One OS thread
  per instance: a pooled instantiate, call and destroy cycle runs 21,900
  times a second from one process and 67,000 from fourteen on an M4 Pro, so
  thread start-up is not what limits a request. What the second thread costs
  is a host call's hand-off: 2.5 us when idle, about 45 us when 14 guests
  and 14 schedulers share 14 cores. Running the guest on the calling
  process's dirty scheduler through Wasmtime's async API would remove the
  hand-off; it changes the execution model (streams, waits, interruption)
  and is not planned until a workload needs it.
- **Fault isolation from Wasmtime itself.** A panic in Wasmtime aborts the
  process (the C API is built with `panic = abort`), and so does running out
  of host memory inside it; [design](design.md), "What can still stop the
  node", lists every case. A `mode => port` running instances in a separate
  OS process would contain that, at the price of a pipe crossing on every
  call and host call and of losing the whole port's instances on a crash
  instead of the node. Not built: the inputs that reach Wasmtime are checked
  first instead.
- **Instruction scan in `preinit/3`.** Wizer refuses modules whose code
  holds `data.drop` or `elem.drop`; `preinit/3` compares tables instead and
  does not read code. See [preinit](preinit.md), "Notes".
- **WASI preview 2 and components.** Not exposed.
- **Spawning guest threads.** The threads proposal validates and shared
  memories can be declared, but nothing lets a guest start a thread: there is
  no `wasi-threads` and no host function for it. A module is one thread.
