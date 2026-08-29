# erlang-wasmtime

Wasmtime bindings for Erlang (also findable as wasmtime-erlang). WebAssembly
modules run natively through Wasmtime's Cranelift compiler, and a module can
call Erlang functions when it needs to, the way `erlang-python` lets Python
call Erlang.

```erlang
{ok, Mod}  = wasmtime:compile({wat, ~"""
    (module
      (import "env" "log" (func $log (param i32) (result i32)))
      (func (export "run") (param i32) (result i32)
        local.get 0 call $log))
    """}),
{ok, Inst} = wasmtime:instantiate(Mod, #{
    imports => #{{~"env", ~"log"} => fun(_Ctx, [N]) -> logger:info("got ~p", [N]), {ok, [N * 2]} end}}),
{ok, [84]} = wasmtime:call(Inst, ~"run", [42]).
```

Nothing raises for guest failures. Compile, link, trap, WASI and host errors
all come back as `{error, #{class => ..., kind => ..., message => ...}}`.

## What you get

- Native execution: Wasmtime 48, statically linked into one NIF.
- Host functions: an import backed by an Erlang fun, run in the calling process.
- Isolation by default: no WASI, no filesystem, no host functions and a 256 MB
  memory cap unless you grant more. Each instance has its own store, memory and
  OS thread.
- Interruption: `timeout` on a call, or `wasmtime:interrupt/1` from any process,
  stops a running guest within 10 ms.
- WASI preview 1 with explicit capabilities: `args`, `env`, preopened `dirs`,
  and stdio redirected to files or inherited.
- Linear memory access from Erlang while the guest is idle or inside a host call.
- References as terms: `funcref`, `externref` (wrapping any Erlang term) and
  GC structs and arrays cross calls, host functions, globals and tables.
- Precompiled modules: compile once, `deserialize/1` in milliseconds.
- Runtime-only builds: `WASMTIME_RUNTIME_ONLY=1` gives a 4 MB NIF without the
  compiler for nodes that only load precompiled modules.
- Host functions served by the caller or by a dedicated process.
- Streams: a long-running guest reads what `send/2` queues and its writes
  arrive as messages, through stdin/stdout for stock WASI programs or the
  `erlang` imports for modules you build.

## Install

```erlang
{deps, [{erlang_wasmtime, "0.1.0"}]}.
```

The first `rebar3 compile` downloads the pinned Wasmtime C API release for your
platform (about 15 MB, checksum verified) and builds the NIF. You need a C
compiler and `curl`; a platform without a prebuilt archive builds Wasmtime
from source with `git`, `cmake` and Rust. See [docs/building.md](docs/building.md)
for offline builds, runtime-only builds and supported platforms.

Requires OTP 27 or later.

## Documentation

- [Run JavaScript](docs/javascript.md): QuickJS in the sandbox, the shortest path to a demo
- [Run Python](docs/python.md): CPython's WASI build, with the standard library
- [Getting started](docs/getting-started.md)
- [Host functions](docs/host-functions.md)
- [WASI](docs/wasi.md)
- [Streams](docs/streams.md): talk to a guest while it runs
- [References](docs/references.md): funcref, externref and GC values as terms
- [Precompiled modules](docs/precompiled.md): compile once, load in milliseconds
- [Building and shipping](docs/building.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Design](docs/design.md): how the NIF is put together, for contributors; see also [CONTRIBUTING.md](CONTRIBUTING.md)
- [Features](docs/features.md): what is implemented, what is refused, what is deferred
- [Examples](examples/README.md): a guest that reads ETS, logs and notifies processes

## Related

- [erlang_wasm](https://github.com/benoitc/erlang_wasm): a WebAssembly runtime
  written in Erlang, no native code. Same API style; pick it when you cannot
  ship a NIF.
- [erlang-python](https://github.com/benoitc/erlang-python): the embedding
  pattern this project copies, for Python.

## License

Apache-2.0
