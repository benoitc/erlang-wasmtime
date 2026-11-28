# Parity with erlang_wasm

Goal: everything a user of erlang_wasm 0.12.0 can call works here with the
same name, arity, options and result shape, or is refused with an error and
listed under "Deferred" in `docs/features.md` with the reason. Modules keep
the `wasmtime_` prefix. Where the two differed, this library changed to match
(decided 2026-11-27).

The manifest in `test/wasmtime_parity_SUITE.erl` is this table for the
machine: it fails when a "done" function is not exported, when a planned one
already is, and, with `ERLANG_WASM_DIR` set, when erlang_wasm exports a
function neither lists. Update both together.

## Functions

| erlang_wasm | Here | Status |
|---|---|---|
| `wasm`: all but the two below | `wasmtime` | done |
| `wasm:extern/2` | `wasmtime` | done, functions only |
| `wasm:encode/1` (0.13.0) | none | refused; `wat2wasm/1` for text |
| `wasm_error` | `wasmtime_error` | done |
| `wasm_limits` | `wasmtime_limits` | done |
| `wasm_engine`: `page_limit/0`, `set_page_limit/1`, `pages_in_use/0`, `stats/0` | `wasmtime_engine` | phase 7, spike |
| `wasm_component`: `host_*` | `wasmtime_component` | done |
| `wasm_component`: `decode`, `prepare`, `instantiate`, `call`, `call_async`, `destroy`, `exports`, `drop_resource`, `import_fun` | `wasmtime_component` | done |
| `wasm_component`: `start_async`, `pump` | `wasmtime_component` | phase 6 |
| `wasm_component`: `snapshot`, `restore`, `acquire`, `release` | none | refused: no component snapshots |
| `wasi`: `run`, `imports` | `wasmtime_wasi` | done; `imports` carries the configuration, not functions |
| `wasi_preview1`: `exit_code`, `imports/1` | `wasmtime_wasi_preview1` | done |
| `wasi_preview1:imports` and the other map builders | none | refused: Wasmtime implements WASI |
| `wasi_preview2`, `wasi_preview3`: `run_command` | `wasmtime_wasi_preview2`, `preview3` | done |
| `wasi_preview2`, `wasi_preview3`: `run_serve` | same | done; `run_serve/4` refused (import maps) |
| `wasi_preview2`, `wasi_preview3`: import maps and `_with` runners | none | refused: Wasmtime implements WASI |
| `wasi_http_transport` | `wasmtime_http_transport` | done |
| `wasi_http_h1` | none | refused: Wasmtime sends requests itself |
| `wasi_http_listener` | `wasmtime_http_listener` | done; HTTP/1.1 only. Extra: `max_connections`, strict request parsing; ends with its starter; a component that cannot run fails `start/1` |
| `wasi_http_h2` | none | refused: no HTTP/2 |
| `wasi_nn` | `wasmtime_wasi_nn` | phase 7 |
| `wasm_instance_worker` | `wasmtime_instance_worker` | done |
| `wasm_actor` | `wasmtime_actor` | done |
| `wasm_script_worker`: `run`, `submit`, `await`, `cancel`, `start_link`, `stop`, `default_limits` | `wasmtime_script_worker` | done |
| `wasm_script_worker`: `channel_write`, `cleanup_stats`, `cleanup_requests` | same | phase 5 |
| `wasm_worker_error` | `wasmtime_worker_error` | done; kinds `result_limit`, `no_reaper`, `cleanup_saturated`, `unauthorised`, `request_finished` come with phase 5 |
| `wasm_worker_adapter` | `wasmtime_worker_adapter` | done; `snapshot_capability`, `defaults` in phase 5 |
| `wasm_javascript_command`, `wasm_python_command` | `wasmtime_*_command` | done |
| `wasm_javascript`, `wasm_python`, `wasm_lua` | same | phase 5 |
| `wasm_adapter_conformance` | `wasmtime_adapter_conformance` | phase 5 |
| `wasm_jit`, `wasm_code_cache`, `wasm_async`, `wasm_memory`, `wasm_snapshot_store` | none or other | compiled tier refused (Wasmtime has one tier); streams phase 6; shared memory phase 7 |

## Options

| erlang_wasm | Here | Status |
|---|---|---|
| `instantiate`: `fuel`, `max_memory_pages`, `timeout`, `profile`, `snapshotable` | same | done |
| `instantiate`: `max_host_calls`, `max_heap_words` | workers | done on workers; refused on instances (`invalid_limits`) |
| `instantiate`: `max_depth` | none | refused (`invalid_limits`) |
| `instantiate`: `link`, `snapshot_hooks`, `compile*` | none | refused (`unsupported_option`) |
| `instantiate`: `resource_limit` | same | done for components; refused for core modules. `transfer_limit` is only here |
| WASI: `args`, `env`, `dirs`, `clocks`, `stdin`, `stdout`, `stderr` | same | done; a `stdin` fun is refused |
| WASI: `random => {seed, N} \| none` | same | done for core modules |
| WASI: `network`, `http` grants, `initial_cwd`, `http_max_body_bytes` | same | done for components, 8 MiB body default; `net` for core modules refused; `max_sockets` and `timeout` in a grant refused |
| HTTP allow and deny by host name | none | refused: grants are by address |
| cache env caps | same names | done, unlimited unless set |

## Errors

Done: `#{class, kind, msg, ctx}`, the five classes, and the kinds of calls,
links, traps, exhaustion, host functions and `proc_exit`. The parity suite
runs the same failing calls on both runtimes.

| Difference | Why |
|---|---|
| `call_indirect` past the table is `out_of_bounds_table_access`, not `undefined_element` | Wasmtime has one trap code for both |
| `malformed` and `invalid` kinds are fewer and follow Wasmtime's wording | the decoder is Wasmtime's |
| kinds only here: `incompatible_module`, `instance_busy`, `interrupted_instance`, `interrupt`, `clock_refused`, `stopped` and others in `features.md` | features erlang_wasm does not have |

## Semantics

| Subject | Status |
|---|---|
| host function context, `{M, F}`, `{trap, R}` | done; the context holds `instance` only |
| `exports/1` | done, index is `undefined` |
| `memory_size/1`, `validate/1`, `func_type_of/2` | done |
| start section bounded by `timeout` | done |
| linking non-function externs across instances | refused |
| streams and futures | phase 6 (`stream<u8>` first); compound elements and `error-context` refused |
| unversioned WASI imports | phase 7 |
| WASI 0.3 cooperative threads, NaN payloads, `wasi_unstable` | phase 7, spikes |

## Phases

3. Done: resource and size limits, `initial_cwd`, address grants for sockets
   and HTTP. The fast path for `list<u8>` is refused: it needs changes in
   Wasmtime itself.
4. Done: serving HTTP, the transport and the listener.
5. Workers: reactor snapshot adapters, `restore_ahead`, reaper (with the
   sweep of leftover request directories), result channel, conformance kit.
6. Patch batch C: streams and futures.
7. `wasi_nn`, unversioned imports, spikes.
