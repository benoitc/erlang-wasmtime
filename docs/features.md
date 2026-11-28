# Features

What is implemented, what is refused explicitly, and what is deferred. When a
feature is missing the runtime says so with an error; it does not approximate.

## Implemented

| Area | Status |
|---|---|
| Compile from binary or `.wat` text | yes, dirty CPU scheduler |
| WebAssembly proposals | Wasmtime 51 defaults, verified by compiling probe modules: bulk memory, wide arithmetic, reference types, multi-value, SIMD, relaxed SIMD, tail calls, extended const, multi-memory, memory64, exceptions, GC and typed function references, threads and shared memories |
| Instantiate with host functions | yes, function imports only; an import you give wins over the WASI function of the same name; `instantiate/3` takes the import map as erlang_wasm does, `instantiate/2` the import map or the options |
| Call exports | yes, `i32`, `i64`, `f32`, `f64`, `v128` values |
| Traps | erlang_wasm's kinds, `class => trap` or `exhaustion` (fuel, call stack) |
| Interruption | `timeout` option and `interrupt/1`, epoch based: the epoch is bumped as they fire, so the guest stops at its next loop back-edge or call |
| Memory cap | `memory_limit`, default 256 MB, enforced by the store limiter |
| Table, element and instance caps | `max_tables`, `max_table_elements`, `max_instances` |
| Memory access from Erlang | `read_memory/3,4`, `write_memory/3,4`, `memory_size/1,2`: the export named `memory` (or the first exported memory) by default, any exported memory by name |
| Precompiled modules | `serialize/1` and `deserialize/1`, Wasmtime's `.cwasm` form; `deserialize_file/1,2` maps the file; see [precompiled](precompiled.md) |
| Pre-initialization | `preinit/3`: run init exports once, get a module starting in their state (memories, mutable globals); init calls as a list or a fun; `remove_exports`; see [preinit](preinit.md) |
| Pooling allocator | `allocator => pooling` with `instances`, `max_memory`, `keep_resident`; copy-on-write memory images |
| Explicit teardown | `destroy/1`: stops the instance and frees its store (and pool slot) before returning |
| Text to binary | `wat2wasm/1` (core modules and components) |
| Components | compiled, validated, precompiled, pooled like modules; `module_kind/1`; `call/3,4` by `Export` or `Interface#Function`, `{ok, Value}`; erlang_wasm's term mapping for every WIT value; host imports keyed `{Interface, Function}` (raw `{ok, [V]}` funs or erlang_wasm's typed `import_fun/2`); resources as integer handles, `drop_resource/2,3`; see [components](components.md) |
| WASI 0.3 | linked beside 0.2 for components with a `wasi` option, on libraries with this project's patches (`features/0`, `wasi_p3`): commands through `run/1,2`, the same options, `wasi:http` client under an `http` grant; see [WASI 0.3](wasi-0-3.md) |
| Component async | `async func` exports through `call/3,4` and `async func` imports as host functions, on libraries with this project's patches (`features/0`, `component_async`); see [components](components.md) |
| Host resources | a `resource` in an interface the import map serves is the host's: `wasmtime_component:host_new/2,3`, `host_get/1`, `host_update/2`, `host_drop/1`, `host_live/0`; the guest's drop removes the entry, or calls your `[resource-drop]<name>` fun |
| WASI 0.2 | for components with a `wasi` option: the same keys as preview 1, `run/1,2`, streamed stdin and stdout, `clocks => monotonic` traps the wall clock (`kind => clock_refused`); `http` grants `wasi:http/outgoing-handler`, to any server or to listed addresses, on full builds; `network` grants `wasi:sockets` the same way; `initial_cwd` |
| Network grants | erlang_wasm's `wasi_net` form: `connect` and `listen` rules by address prefix and port, `resolve`, `tcp`, `udp`; checked by Wasmtime on every address, and an HTTP request connects to the address that passed; on libraries with this project's patches (`features/0`, `wasi_limits`) |
| Serving HTTP | `wasmtime_wasi_preview2:run_serve/3` (and preview3's): one request to a `wasi:http` handler, 0.2 or 0.3, with trailers and a bounded response body; full builds with this project's patches (`features/0`, `wasi_http_serve`) |
| Component limits | `resource_limit` (host and WASI resource handles), `transfer_limit` (bytes copied to the host per call), `http_max_body_bytes` (8 MiB by default), `http_max_field_bytes` |
| Host functions in a dedicated process | `host => Pid` at instantiate, `handle_host_call/2` in that process |
| Non-blocking calls | `call_async/3` and `await/2,3` |
| Fuel metering | `compile(Bin, #{fuel => true})`, `call/4` with `fuel`, `fuel_remaining/1`; `kind => out_of_fuel` |
| Structured traps | `ctx.trace` on trap errors: `[#{func_index, func_offset, func_name, module_name}]`, innermost first |
| Validation without compiling | `validate/1`, `validate/2` with options |
| Compile options | `compile/2`: `opt_level` (`none`, `speed`, `speed_and_size`), `proposals` on or off, `fuel`; `module_options/1`; `deserialize/2` to pick the engine |
| Globals and tables from Erlang | `get_global/2` (the value in a list, as erlang_wasm; `global_get/2` is deprecated), `global_set/3`, `table_size/2`, `table_get/3`, `table_set/4`, `table_grow/3,4` |
| References across the boundary | `funcref`, `externref` and GC values as `ref()` terms, `null`, `{i31, N}`: in calls, host signatures, globals and tables; `externref/2` wraps a term; `call_ref/3,4`; `struct_get/set`, `array_len/get/set`; `gc/1`; see [references](references.md) |
| WASI stdio in memory | `stdin => {binary, _}`, `stdout`/`stderr => capture` with `read_output/1` and `output_limit`; `args`/`env => inherit` |
| Streams | `send/2`, `close/1`, `inbox_limit`; `stdin`/`stdout`/`stderr => stream` (a streamed stdout looks like a terminal to the guest, so lines leave as written); the `erlang.send` and `erlang.recv` imports; `{wasmtime_stream, Ref, Kind, Bytes}` to the `stream` process; see [streams](streams.md) |
| Runtime-only builds | `WASMTIME_RUNTIME_ONLY=1`: no compiler, about 7 MB; `features/0` reports the linked library's capabilities; see [building](building.md) |
| Source build fallback | a platform without a prebuilt archive compiles the C API itself |
| WASI preview 1 | args, env, preopened dirs with read or write, stdio to file or inherited; `clocks => monotonic` refuses wall and CPU clocks with `ENOTCAPABLE` |
| Snapshots | `snapshot/1,2` of an instance made with `snapshotable => true`, `restore/3`, `snapshot_info/1`, `save_snapshot/2`, `load_snapshot/2`, `compatibility_key`; core modules, memories and mutable globals; see [snapshots](snapshots.md) |
| Script workers | `wasmtime_script_worker` (`run/2,3`, `submit/2,3`, `await/3`, `cancel/2`) over an adapter (`wasmtime_worker_adapter`); `wasmtime_javascript_command` and `wasmtime_python_command`; a directory, a deadline and bounded output per request; see [scripting](scripting.md) |
| Instance linking | `extern/2`: a core function export as another instance's import, signatures checked |
| erlang_wasm's modules | `wasmtime_wasi`, `wasmtime_wasi_preview1`, `preview2`, `preview3` (running programs), `wasmtime_component` (`instantiate`, `call`, `destroy` and the rest), `wasmtime_actor`; see [switching](erlang-wasm.md) |
| Output sinks and randomness | `stdout`/`stderr` as a pid, io device or fun; `random => {seed, N} \| none` for core modules |
| Actors | `wasmtime_actor`: a component as a process with a bounded queue; see [actors](actors.md) |
| Worker limits | `max_host_calls`, `max_heap_words` on both workers |
| Instance worker | `wasmtime_instance_worker`: one instance in a process, a deadline per request, `fresh` or `reuse` between requests; see [workers](worker.md) |
| Module cache | `load/1,2`, `load_file/1`, `unload/1`: one compiled module per source and option set for the node, a claim per load, given back by `unload/1` or when the loader dies; caps `max_resident_modules`, `max_resident_module_bytes`, `max_module_loads_per_second`, `max_module_bytes`; needs the application started |
| Function types without an instance | `func_types_of/1`, `func_type_of/2`, on a module or on bytes |
| Limit presets | `wasmtime_limits`: `untrusted/0`, `trusted/0`, `merge/2`, `validate/1`; `timeout`, `fuel` and `max_memory_pages` at instantiate, the first two as defaults of every call |
| Errors on one line | `format_error/1`, for logs |
| Caller death | the abandoned call is interrupted, queued calls proceed |
| Host function timeout | `host_timeout`, default 30 s |

## Execution model

- One OS thread per instance owns the Wasmtime store. Calls are queued; one runs
  at a time.
- The calling process waits in `receive`; it is never blocked inside a NIF
  while the guest runs, so schedulers are not held.
- Host functions run in the calling process (or the `host` process).
- One engine per distinct compile option set. Instances of a module share
  its compiled code, its memory image and a linker per import shape;
  nothing they can change.
- Core modules and components run the same way: same queue, same host
  calls, same `timeout`, `interrupt/1` and `destroy/1`.
- Erlang holds a handle; the instance itself is owned jointly by that handle
  and its thread. Dropping the handle tells the thread to stop and never
  blocks a scheduler. A caller that dies has its running call interrupted and
  its queued calls dropped.
- `timeout` cancels the request by id: its result is dropped in the NIF, so
  nothing lands in the mailbox afterwards. A result that arrived just as the
  timeout fired is returned as the answer.
- Stopping an instance (`timeout`, `interrupt/1`, `destroy/1`) ends its
  streamed stdin: a read blocked inside Wasmtime can only be woken that way.

## Refused explicitly

Errors have erlang_wasm's shape, `#{class, kind, msg, ctx}`; see
`wasmtime_error`.

| Request | `class`, `kind` |
|---|---|
| Bytes that are not a module (`ctx.detail` says why) | `malformed`: `magic_header_not_detected`, `unknown_binary_version`, `unexpected_end`, `syntax_error` for text, `malformed_module` and others |
| A module that does not validate | `invalid`: `type_mismatch`, `unknown_local` and the other `unknown_*`, `invalid_module` |
| A precompiled module from another Wasmtime, CPU or option set | `link`, `incompatible_module` |
| Import the module needs and was not given | `link`, `unknown_import` |
| Import of another type | `link`, `incompatible_import_type` |
| An import map value that is no fun and no `{Module, Function}` | `link`, `bad_import` |
| Non-function import from Erlang | `link`, `unsupported_import` |
| A module needing more memory, tables or instances than allowed | `exhaustion`, `memory_limit`, `table_limit` or `instance_limit` |
| `exnref` in a call or host signature, or `v128` and references in one signature | `link`, `unsupported_type` |
| A reference used with another instance | `trap`, `foreign_reference` |
| `null` for a non-nullable type, a reference of the wrong family, an `{i31, N}` out of range | `link`, `argument_type` as an argument, `badarg` elsewhere |
| Memory access while the guest runs | `link`, `instance_busy` |
| Memory access on an instance without memory | `link`, `no_memory` |
| Out of range memory access | `trap`, `out_of_bounds_memory_access` |
| Out of range table or array index | `trap`, `out_of_bounds_table_access` or `out_of_bounds_array_access` |
| Unknown export, or one that is no function | `link`, `unknown_export` or `not_a_function` |
| Wrong argument count or type | `link`, `argument_arity` or `argument_type` |
| A host function calling the instance it runs on | `link`, `reentrant` |
| A host function that fails, times out or answers the wrong values | `trap`, `host_error`, the reason in `ctx.reason` |
| `proc_exit` | `trap`, `host_error`, the status in `ctx.wasi_exit` |
| A call past its `timeout` | `exhaustion`, `timeout` |
| `compile/1`, `{wat, _}`, `serialize/1` or the `wasi` option on a build without them | `link`, `unavailable` |
| `fuel` on a module compiled without metering | `link`, `fuel_disabled` |
| A 33rd distinct compile option set | `exhaustion`, `too_many_configurations` |
| `opt_level` other than `speed`, or a proposal the library lacks, on a build without it | `link`, `unavailable` |
| Writing a constant global | `link`, `immutable` |
| `send/2` past `inbox_limit`, or after `close/1` | `exhaustion`, `inbox_full`; `link`, `closed` |
| An `imports` entry for `erlang.send` or `erlang.recv` | `link`, `reserved_import` |
| `erlang.send` or `erlang.recv` imported with another type | `link`, `unsupported_type` |
| `stdout` or `stderr => stream` on a runtime-only build of a platform without a shim in `priv/shims` | `link`, `unavailable` |
| Pooling options out of range | `link`, `badarg` |
| A pool whose address space the host cannot reserve | `exhaustion`, `pool_too_large` |
| A module whose memory does not fit a pool slot | `exhaustion`, `pool_limit` |
| One instance more than the pool holds | `exhaustion` or `link` |
| `allocator => pooling` on a build without the pooling allocator | `link`, `unavailable` |
| `preinit/3` on a module importing a memory, table or global | `link`, `unsupported_import` |
| `preinit/3` on GC types or a mutable reference global | `link`, `unsupported_type` |
| `preinit/3` on a shared memory, a component, or a reserved export name | `link`, `unsupported` |
| `preinit/3` when an init call changed a table | `link`, `table_changed` |
| `preinit/3` on bytes that are not a module | `malformed`, `malformed` |
| A call, or a ref of the instance, after `destroy/1` | `link`, `stopped` |
| A value that does not fit a component type (bad UTF-8, surrogate char, out of range, unknown case or flag, missing field) | `link`, `argument_type` |
| A dropped or unknown resource handle | `link`, `badarg` or `argument_type` |
| A component function returning or taking a `stream`, `future` or `error-context`, or a host import taking one | `link`, `unsupported_type` |
| A component call after it was interrupted | `link`, `interrupted_instance` |
| A component instance called after it trapped | `trap`, `cannot_enter_component` (the Component Model forbids re-entering it) |
| `load/1,2` past `max_resident_modules` (256), or without the application | `exhaustion`, `cache_full`; `link`, `not_started` |
| `snapshot/1,2` on an instance not made for it, or of a module not from `load/1,2`; an image restored or loaded under another key or module | `invalid`, `not_snapshotable`, `module_not_loaded` or `snapshot_incompatible` |
| `snapshot/1,2` while a call runs | `link`, `busy` |
| A `network` or `http` grant, `initial_cwd` or a component limit on a library without the patches, or an `http` grant on a build without `wasi:http` | `link`, `unavailable` |
| A `network` or `http` grant for a core module | `link`, `unsupported` |
| `initial_cwd`, `http_max_body_bytes` or `http_max_field_bytes` for a core module; `max_sockets` or `timeout` in a grant | `link`, `unsupported_option` |
| `resource_limit` or `transfer_limit` for a core module; a value that is no limit | `link`, `unsupported_option` or `invalid_limits` |
| An HTTP limit that is no positive integer | `link`, `wasi_config` |
| A network grant that cannot be read | raises `{bad_net_grant, Term}` |
| Headers past `http_max_field_bytes`; a body past `http_max_body_bytes` | `trap` for headers (`wasi:http` has no error for it); the guest's request fails for a body |
| `run_serve/3` on a library that cannot serve; a request that is not one | `link`, `unavailable` or `badarg` |
| A host resource past `resource_limit` | `trap`, `resource_limit_reached` |
| More data from a component in one call than `transfer_limit` | `exhaustion`, `hostcall_fuel` |
| A `profile` other than `plugin` or `script` | `link`, `unknown_profile` |
| erlang_wasm's `max_depth` anywhere, `max_heap_words` or `max_host_calls` on `instantiate` or `call`, or a limit of the wrong type | `link`, `invalid_limits` |
| A host function past `max_host_calls` in a worker | `exhaustion`, `host_call_limit` |
| A source past `max_module_bytes`; a load past the cache's byte or rate cap | `exhaustion`, `module_too_large`, `cache_full` or `load_rate_exceeded` |
| `extern/2` of something that is no core function, or on a snapshotable instance; an extern of another signature | `link`, `unsupported_extern`, `instance_snapshotable` or `incompatible_import_type` |
| `random => {seed, _}` or `none` for a component; a `stdout` atom that names no process | `link`, `unsupported_option` |
| erlang_wasm's `link`, `snapshot_hooks`, `compile`, `compile_quality`, `compile_after` options; a `wasi` key or value this runtime does not have (`net`) | `link`, `unsupported_option`, the keys in `ctx.keys` |
| A core-module accessor on a component instance | `link`, `component` |
| The WASI wall clock under `clocks => monotonic` | `trap`, `clock_refused` |

## Differences from erlang_wasm

- `exports/1` answers `{Kind, undefined}`: Wasmtime does not report the
  index of an export.
- A `call_indirect` past the end of its table is `out_of_bounds_table_access`
  here; erlang_wasm says `undefined_element`. Wasmtime reports both with one
  trap code.
- `malformed` and `invalid` kinds follow Wasmtime's wording, so a rare
  failure is `malformed_module` or `invalid_module` where erlang_wasm names
  it.

## Deferred

- **WASI import maps.** erlang_wasm builds WASI from Erlang import maps you
  can change function by function (`wasi_preview1:imports/1`,
  `wasi_preview2:io/0` and the rest, `wasi_http:http/1`, the `_with`
  runners). Here Wasmtime implements WASI: you configure it with the `wasi`
  options. An import you give still wins for a core module; a component's
  WASI cannot be overridden.
- **Sharing more than functions.** `extern/2` hands out core functions only:
  a memory, table, global or tag belongs to one store, and Wasmtime cannot
  share it with another instance. erlang_wasm's `link` option has no
  counterpart for the same reason.
- **erlang_wasm's default cache caps.** It limits a node to 64 MiB per
  module, 2 GiB resident and 50 loads a second unless told otherwise; here
  those three are unlimited unless set.
- **`wasm:encode/1`.** erlang_wasm writes a module it holds as `.wasm`
  bytes. Wasmtime does not keep the module in a form it can write back;
  `wat2wasm/1` covers the text format.
- **HTTP/2.** erlang_wasm's `wasi_http_h2` transport has no counterpart.
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
- **Streams and futures across the boundary.** `stream`, `future` and
  `error-context` values are refused with `kind => unsupported_type`: the C API
  cannot represent them. erlang_wasm passes streams and futures.
- **`preinit/3` for components.** Core modules only; componentize-py
  pre-initializes what it builds.
- **Snapshot adapters for script workers.** erlang_wasm's `wasm_javascript`,
  `wasm_python` and `wasm_lua` start the interpreter once and restore a
  snapshot per request. Here the command adapters start it for every
  request: a snapshot does not carry what WASI holds for an instance, and
  the reactor builds and their protocol are not ported.
- **The reaper.** erlang_wasm journals every request so a restarted node
  removes what a crashed one left, and bounds cleanup work. Here a
  request's directory is removed by its worker when the request ends; a
  node crash leaves it. `cleanup_stats/0` and `cleanup_requests/0` do not
  exist.
- **Other script worker options.** `restore_ahead`, `compiled`, the heap
  floors, a result channel apart from stdout, and the conformance kit
  module are erlang_wasm's and have no counterpart yet.
- **Your own HTTP transport, and an HTTP listener.** Wasmtime sends the
  guest's requests: there is no `http_transport` to replace it and no
  `wasi_http_listener` to serve connections yet. erlang_wasm has both.
- **erlang_wasm's `run_serve/4`.** It takes an import map built beforehand;
  here the imports are Wasmtime's.
- **Error code payloads.** A `wasi:http` error code that carries a record,
  such as `DNS-error`, has `undefined` as its payload.
- **`max_sockets` and `timeout` in a network grant.** Wasmtime's sockets
  take neither. `resource_limit` bounds how many WASI resources a component
  holds, sockets among them, and the call's `timeout` stops a waiting guest.
- **Sockets without component async.** On such a library (`features/0`) a
  guest blocked on a socket is not stopped by `timeout` or `interrupt/1`
  until the peer answers or closes.
- **A fast path for `list<u8>`.** A list of bytes crosses one value per
  byte: about 40 ms per megabyte each way and back, against well under 1 ms
  for a `string`. The cost is in Wasmtime's dynamic component values, which
  its C API is built on. Raise `transfer_limit` for large lists, or pass
  them through a file or a stream.
- **Unversioned WASI imports.** A component importing `wasi:*` without a
  version (accepted by erlang_wasm) is a link error: Wasmtime links WASI
  by version.
- **Spawning guest threads.** The threads proposal validates and shared
  memories can be declared, but nothing lets a guest start a thread: there is
  no `wasi-threads` and no host function for it. A module is one thread.
