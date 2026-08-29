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
| Interruption | `timeout` option and `interrupt/1`, epoch based, 10 ms granularity |
| Memory cap | `memory_limit`, default 256 MB, enforced by the store limiter |
| Table, element and instance caps | `max_tables`, `max_table_elements`, `max_instances` |
| Memory access from Erlang | `read_memory/3`, `write_memory/3`, `memory_size/1` on the export named `memory` or the first exported memory |
| WASI preview 1 | args, env, preopened dirs with read or write, stdio to file or inherited |
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
| `funcref`, `externref`, GC types in a call or host signature | `kind => unsupported_type` |
| Memory access while the guest runs | `kind => busy` |
| Memory access on an instance without memory | `kind => no_memory` |
| Out of range memory access | `kind => out_of_bounds` |
| Wrong argument count or type | `kind => badarity`, `kind => badarg` |
| A host function calling the instance it runs on | `kind => reentrant` |

## Deferred

- **Reference and GC values across the boundary.** Modules using them
  internally run; only conversion to and from Erlang terms is missing. Needs a
  rooting and lifetime design.
- **Several memories.** Only one memory is reachable from Erlang. A memory-name
  argument is the planned extension.
- **Precompiled modules (`.cwasm`).** Would allow shipping compiled modules and
  running them on Wasmtime's 1.8 MB runtime-only build. Tied to the exact
  Wasmtime version and CPU features; needs its own docs and tests.
- **Thread pool.** Thread per instance is fine for hundreds of long-lived
  instances, not for thousands of short-lived ones per second. A pool where an
  instance is bound to a thread only during a call keeps the same public API.
- **Host functions in another process.** Today the caller handles them.
  Routing to a dedicated handler process is not offered.
- **Fault isolation from Wasmtime itself.** A bug in Wasmtime would take the VM
  down, like any NIF. A `mode => port` running the instance in a separate OS
  process is the answer if that matters; same API, not built.
- **WASI preview 2 and components.** Not exposed.
- **Spawning guest threads.** The threads proposal validates and shared
  memories can be declared, but nothing lets a guest start a thread: there is
  no `wasi-threads` and no host function for it. A module is one thread.
