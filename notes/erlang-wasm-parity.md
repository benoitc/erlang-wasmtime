# Parity with erlang_wasm

Goal: everything a user of erlang_wasm (0.10.2) can call has an equivalent
here with the same name, or is refused and listed under "Deferred" in
`docs/features.md` with the reason. Decided 2026-11-19: scope is everything
feasible, a name that differs is deprecated in favour of erlang_wasm's, and
the workers keep erlang_wasm's module names.

This file is the plan. Update it as phases land.

## Phase 1: the `wasm` module's names

| erlang_wasm | Here today | Difference | Resolution |
|---|---|---|---|
| `instantiate(M, Imports)`, `instantiate(M, Imports, Opts)` | `instantiate(M, Opts)` with an `imports` key | same `{Module, Name}` keys; arity 2 means something else | add `instantiate/3`; `instantiate/2` takes either map (import keys are tuples, option keys atoms); the `imports` option is deprecated in the docs |
| `get_global(Inst, Name) -> {ok, [V]}` | `global_get/2 -> {ok, V}` | name and result shape | add `get_global/2` with erlang_wasm's shape; deprecate `global_get/2` |
| `format_error/1` | none | error maps here have `message`, there `msg` and `ctx` | add, over this library's map |
| `func_type_of(Bytes, Name)`, `func_types_of(Bytes)` | none; `exports/1` gives kinds only | needs function types from the C API | add a NIF listing export function types; both take bytes or a module |
| `exports(Inst) -> #{Name => Kind}` | `exports(Module) -> [{Name, Kind}]` | argument and result | accept an instance too; keep the list. To confirm |
| `load/1,2`, `load_file/1`, `unload/1` | `compile/1,2`, `deserialize_file/1,2` | a node-wide cache with claims | add a cache keyed by bytes hash and compile key; needs an owner process, so the application gets a supervisor |
| `wasm_limits`: `untrusted/0`, `trusted/0`, `default/0`, `merge/2`, `validate/1` | `memory_limit` at instantiate; `timeout`, `fuel` per call | `max_memory_pages`, `max_depth`, `max_heap_words`, `max_host_calls` have no direct equivalent | `wasmtime_limits` with the same functions; `instantiate/3` accepts `max_memory_pages`, `timeout` and `fuel` as defaults for every call; the others are refused with `invalid_limits` and documented |
| `profile => plugin \| script` | none | compile tier choice, no meaning on Wasmtime | accepted and ignored. To confirm |
| `read_memory/3`, `write_memory/3`, `memory_size/1`, `call/3,4`, `compile/1,2`, `validate/1`, `destroy/1` | same | none found | check option keys of `call/4` |
| `pin/2`, `release/2`, `release_all/1` | `ref()` terms keep their object alive | not needed | add as no-ops returning `ok`, so shared code runs. To confirm |
| `acquire/1`, `release/1` (snapshots) | none | phase 3 | |
| `extern/2`, `extern_sibling/2`, `call_func/3` | none | instances cannot share a store | refuse, list under Deferred |

## Phase 2: `wasm_instance_worker`

One instance in a process: `start_link/1,2`, `call/3,4`, `stop/1`,
`info/1`, isolation policy, limits nested under `limits`. Erlang only, on
`call/4`, `timeout` and `destroy/1`.

Blocking question: hornbeam depends on erlang_wasm (application `wasm`). Two
applications that both ship a module named `wasm_instance_worker` cannot be
in one release. Same names means a node runs one runtime or the other, never
both. If hornbeam must be able to load both, the modules need a prefix here
and a behaviour or a configuration key to pick one.

## Phase 3: snapshots

`snapshot/1,2`, `restore/3`, `snapshot_info/1`, `save_snapshot/2`,
`load_snapshot/2`, `acquire/1`, `release/1`. Built on the preinit machinery:
read memories and globals of a live instance, write a pre-initialized module
and cache its compiled form; `restore/3` instantiates it. Open points: the
image is a module here, not a memory copy, so capture costs a compile unless
cached; tables are not carried (preinit's rule); components are not covered
by preinit.

## Phase 4: `wasi:http` and network grants

The C API has `wasmtime_component_linker_add_wasi_http` and all-or-nothing
network switches (`wasi_config_inherit_network`,
`wasi_config_allow_ip_name_lookup`). First step is a spike: what the host
can decide per request and per address. erlang_wasm's `wasi_net` grants by
address; if the C API cannot, the option is refused for anything narrower
than all or nothing.

## Phase 5: host resources, component async, WASI 0.3

`wasm_component:host_new/2,3`, `host_get/1`, `host_update/2`,
`host_drop/1`; `call_async`, `start_async`, `pump`; streams and futures.
Each starts with a C API check. Both are under "Deferred" today.

## Phase 6: script workers

`wasm_script_worker` with the JavaScript, Python and Lua adapters and the
cleanup machinery. Depends on phases 2 and 3. Largest piece; plan it
separately once those are in.

## Not planned

`wasi_nn` (nothing in the C API headers), linking instances (`extern/2`),
the page budget (`wasm_engine`), the compiled tier's caches.
