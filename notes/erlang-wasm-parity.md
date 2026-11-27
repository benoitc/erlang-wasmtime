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
| `wasm:extern/2`, `call_func/3` | `wasmtime` | phase 2, functions only |
| `wasm_error` | `wasmtime_error` | done |
| `wasm_limits` | `wasmtime_limits` | done |
| `wasm_engine`: `page_limit/0`, `set_page_limit/1`, `pages_in_use/0`, `stats/0` | `wasmtime_engine` | phase 7, spike |
| `wasm_component`: `host_*` | `wasmtime_component` | done |
| `wasm_component`: `decode`, `prepare`, `instantiate`, `call`, `call_async`, `destroy`, `exports`, `drop_resource`, `import_fun` | `wasmtime_component` | phase 2 |
| `wasm_component`: `start_async`, `pump` | `wasmtime_component` | phase 6 |
| `wasm_component`: `snapshot`, `restore`, `acquire`, `release` | none | refused: no component snapshots |
| `wasi`: `run`, `imports` | `wasmtime_wasi` | phase 2 |
| `wasi_preview1:exit_code/1` | `wasmtime_wasi_preview1` | phase 2 |
| `wasi_preview1:imports` and the other map builders | none | refused: Wasmtime implements WASI |
| `wasi_preview2`, `wasi_preview3`: `run_command` | `wasmtime_wasi_preview2`, `preview3` | phase 2 |
| `wasi_preview2`, `wasi_preview3`: `run_serve` | same | phase 4 |
| `wasi_preview2`, `wasi_preview3`: import maps and `_with` runners | none | refused: Wasmtime implements WASI |
| `wasi_http_listener`, `wasi_http_h1`, `wasi_http_transport` | `wasmtime_http_*` | phase 4 |
| `wasi_http_h2` | none | refused: no HTTP/2 |
| `wasi_nn` | `wasmtime_wasi_nn` | phase 7 |
| `wasm_instance_worker` | `wasmtime_instance_worker` | done |
| `wasm_actor` | `wasmtime_actor` | phase 2 |
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
| `instantiate`: `max_host_calls`, `max_heap_words` | workers | phase 2; refused now (`invalid_limits`) |
| `instantiate`: `max_depth` | none | refused (`invalid_limits`) |
| `instantiate`: `link`, `snapshot_hooks`, `compile*`, `resource_limit` | none | refused (`unsupported_option`); `resource_limit` in phase 3 |
| WASI: `args`, `env`, `dirs`, `clocks`, `stdin`, `stdout`, `stderr` | same | done; stdio to a pid or io device in phase 2 |
| WASI: `random => {seed, N} \| none` | same | phase 2; refused now |
| WASI: `net`, HTTP allow and deny, `initial_cwd` | same | phase 3; refused now |
| limits cache env caps | `load/2` | phase 2 |

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

2. Missing API in Erlang only.
3. Patch batch A: resource and size limits, `initial_cwd`, address grants for
   sockets and HTTP, fast path for `list<u8>`.
4. Patch batch B: serving HTTP.
5. Workers: reactor snapshot adapters, `restore_ahead`, reaper, result
   channel, conformance kit.
6. Patch batch C: streams and futures.
7. `wasi_nn`, unversioned imports, spikes.
