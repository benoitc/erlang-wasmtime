# Spike: component async and WASI 0.3 on the Wasmtime 51 C API

Done 2026-11-27 by reading the v51.0.0 C API sources and headers. Nothing
below has been built or run, except the check that the current engine
refuses a component using `stream`.

## What the C API gives

| Need | State |
|---|---|
| Enable component model async | `wasmtime_config_wasm_component_model_async_set` and two related setters |
| Async instantiate and call | `..._instantiate_async`, `..._func_call_async`, `..._add_wasip2_async`, `..._add_wasi_http_async` |
| Async host functions | `..._instance_add_func_async` |
| WASI 0.3 linker | none; `wasmtime-wasi` is built without `p3` |
| `stream`, `future`, `error-context` values | none; converting one is a `todo!()` in `crates/c-api/src/component/val.rs` |

## What can take the node down

1. **A stream, future or error-context value reaching the C API.** The
   conversion panics and the C API aborts on panic. It happens for a result
   of a call and for an argument of a host function. Today the engine does
   not enable component model async, so such a component does not compile.
   Before enabling it, refuse by type every export result and host import
   parameter that holds one, at any depth.
2. **Driving the call future ourselves.** `wasmtime_call_future_poll` polls
   with a no-op waker and no Tokio runtime. WASI clocks sleep on Tokio, so a
   guest that sleeps would panic, and a waiting call could only be spun on.
   Do not use it.

## Patches needed

1. A blocking call in the C API: run `Func::call_async` under
   `wasmtime_wasi::runtime::in_tokio` on the instance thread, which may
   block. It needs a way to cancel: the epoch only stops running guest code,
   not a call waiting on a timer or a socket, so `timeout`, `interrupt/1`
   and a dead caller must wake it.
2. The same for instantiate.
3. `wasmtime_component_linker_add_wasip3` and the HTTP one, with the `p3`
   features in `crates/c-api/Cargo.toml`.
4. TCP and UDP switches on `wasi_config_t` (wasmtime issue 15388).
5. Optional, later: host access to streams and futures. The Rust types are
   statically typed (`StreamReader<T>`), so a dynamic C interface is the
   large piece of work.

## What this means for the scope

- **Feasible with patches 1 to 3:** running WASI 0.3 commands, and calling
  async exports whose values hold no stream or future. Streams between the
  guest and Wasmtime's own WASI host (stdio, files, sockets, HTTP bodies)
  stay inside Wasmtime and need no C support.
- **Not feasible without patch 5:** passing a stream or future between
  Erlang and a guest, which is erlang_wasm's `start_async/4` with
  `{stream, u8}`.

## Build consequences

- macOS builds use Wasmtime's own archives. Patches 1 to 4 add functions the
  NIF calls, so macOS needs archives built by this project, like Linux and
  FreeBSD, or the new features are unavailable on macOS.
- The runtime-only build turns every feature off and then picks:
  `scripts/build-wasmtime.sh` has to add component model async.
