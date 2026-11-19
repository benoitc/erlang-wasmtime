# Parity with erlang_wasm

Goal: everything a user of erlang_wasm (0.10.2) can call has an equivalent
here with the same name, or is refused and listed under "Deferred" in
`docs/features.md` with the reason. Decided 2026-11-19: scope is everything
feasible, a name that differs is deprecated in favour of erlang_wasm's, and
modules keep erlang_wasm's API under a `wasmtime_` prefix so both
applications fit in one release.

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

## Phase 2: `wasmtime_instance_worker`

One instance in a process: `start_link/1,2`, `call/3,4`, `stop/1`,
`info/1`, isolation policy, limits nested under `limits`. Erlang only, on
`call/4`, `timeout` and `destroy/1`.

Decided 2026-11-19: no module here may collide with erlang_wasm's, since
hornbeam loads both. Same API, `wasmtime_` prefix: `wasmtime_instance_worker`,
`wasmtime_script_worker`, `wasmtime_limits`, `wasmtime_component`.

## Phase 3: snapshots

`snapshot/1,2`, `restore/3`, `snapshot_info/1`, `save_snapshot/2`,
`load_snapshot/2`, `acquire/1`, `release/1`. Built on the preinit machinery:
read memories and globals of a live instance, write a pre-initialized module
and cache its compiled form; `restore/3` instantiates it. Open points: the
image is a module here, not a memory copy, so capture costs a compile unless
cached; tables are not carried (preinit's rule); components are not covered
by preinit.

## Phase 4: `wasi:http` and network access

Spike done 2026-11-19 on the Wasmtime 48 C API headers:

- `wasmtime_component_linker_add_wasi_http` and
  `wasmtime_context_set_wasi_http` give a component `wasi:http/types` and
  `wasi:http/outgoing-handler`. There is no configuration: no hook to allow
  or refuse a request, no way to supply the transport. Wasmtime makes the
  request itself. So outgoing HTTP is all or nothing.
- Nothing lets the host build an incoming request or a response outparam,
  so `wasi:http/incoming-handler` cannot be called: no serving.
- Sockets: `wasi_config_inherit_network` and
  `wasi_config_allow_ip_name_lookup`. All or nothing, no grant per address.
- The full archives have `WASMTIME_FEATURE_WASI_HTTP`; the runtime-only
  archives are built without it and would need a new revision.

Done 2026-11-19 (maintainer: explicit opt-in): `http => all`, off by
default, proven with the `httpget` fixture. `network => all` turned out not
to work: Wasmtime 48's `WasiCtxBuilder` derives `Default`, so TCP and UDP
start off, and the C API has `wasi_config_inherit_network` but no
`allow_tcp`. It is refused with `kind => unavailable` and listed under
Deferred; RELEASING.md says to look again at a Wasmtime bump.

## Phase 5: host resources, component async, WASI 0.3

Spike done 2026-11-19:

- Host resources are feasible: `wasmtime_component_resource_host_new(owned,
  rep, ty)` and `wasmtime_component_linker_instance_add_resource` exist. To
  do: `wasmtime_component:host_new/2,3`, `host_get/1`, `host_update/2`,
  `host_drop/1`, with the table of host objects on the Erlang side.
- Component async is not: `wasmtime_component_func_call_async` exists, but
  `stream`, `future` and `error-context` are types only, with no value kind
  to build or read one, and every engine here has `concurrency_support` off
  (the runtime-only library records it in `.cwasm` files). WASI 0.3 depends
  on it. Stays under Deferred.

## Phase 6: script workers

`wasm_script_worker` with the JavaScript, Python and Lua adapters and the
cleanup machinery. Depends on phases 2 and 3. Largest piece; plan it
separately once those are in.

## Not planned

`wasi_nn` (nothing in the C API headers), linking instances (`extern/2`),
the page budget (`wasm_engine`), the compiled tier's caches.

## Status

- 2026-11-19, phase 1, done on `wasm-parity`: `instantiate/3`,
  `get_global/2` (`global_get/2` deprecated), `format_error/1`,
  `func_types_of/1`, `func_type_of/2`, `wasmtime_limits` with `timeout`,
  `fuel` and `max_memory_pages` at instantiate.
- 2026-11-19, phase 1 complete on `wasm-parity`: the module cache
  (`load/1,2`, `load_file/1`, `unload/1`, with `wasmtime_app`,
  `wasmtime_sup` and `wasmtime_module_cache`), `exports/1` on an instance,
  `pin/2`, `release/2`, `release_all/1` as no-ops, `profile` accepted.
  `load/1,2` compiles: it does not take a `.cwasm`.
- 2026-11-19, phase 2 done: `wasmtime_instance_worker` with
  `wasmtime_worker_SUITE` and `docs/worker.md`. A deadline interrupts the
  guest; the worker is not killed as erlang_wasm's is.
- 2026-11-19, phase 3 done: `snapshot/1,2`, `restore/3`, `snapshot_info/1`,
  `save_snapshot/2`, `load_snapshot/2`, `acquire/1`, `release/1`, with
  `wasmtime_snapshot_SUITE` and `docs/snapshots.md`. Not done: components,
  capturing a restored instance again, erlang_wasm's on-disk format.
- 2026-11-19: spikes for phases 4 and 5 done, findings above.
- 2026-11-19, phase 4 done as far as the C API goes: `http => all`.
- Next: host resources (phase 5), then script workers.
