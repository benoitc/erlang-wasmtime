# Workers

`wasmtime_instance_worker` is one instance in one process: it runs one
request at a time, puts a deadline on each, and by default gives every
request a fresh instance. You need it when a module you did not write
handles requests, and whenever several processes would otherwise share an
instance. It has the functions of erlang_wasm's `wasm_instance_worker`.

## Start one

```erlang
{ok, _} = application:ensure_all_started(erlang_wasmtime),
{ok, Mod} = wasmtime:load_file("plugin.wasm"),
{ok, W} = wasmtime_instance_worker:start_link(Mod, #{
    imports => #{{~"env", ~"log"} => fun(_Ctx, [N]) -> logger:info("~p", [N]), {ok, []} end},
    limits => wasmtime_limits:untrusted(),
    name => plugin
}).
```

In a supervision tree:

```erlang
#{id => plugin, start => {wasmtime_instance_worker, start_link, [Mod, Opts]}}
```

## Run a request

```erlang
{ok, [3]} = wasmtime_instance_worker:call(W, ~"add", [1, 2]),
{error, #{kind := timeout}} = wasmtime_instance_worker:call(W, ~"spin", [], 100).
```

`call/3` uses `worker_timeout` from the application environment, five
seconds unless you set it. `call/4` takes the deadline of the request, in
milliseconds or `infinity`.

## Choose an isolation policy

```erlang
{ok, W} = wasmtime_instance_worker:start_link(Mod, #{isolation => reuse}).
```

| Policy | Between requests | Use it for |
|---|---|---|
| `fresh` (default) | the instance is destroyed and a new one made: no memory, global or table content survives | code you did not write |
| `reuse` | the instance is kept, state persists | modules that are stateless by construction, or that you trust |

## Give it WASI or other options

`options` takes any `wasmtime:instantiate/3` option; `limits` goes on top.

```erlang
{ok, W} = wasmtime_instance_worker:start_link(Mod, #{
    options => #{wasi => #{args => [~"prog"], stdout => capture}},
    limits => #{timeout => 2000, max_memory_pages => 1024}
}).
```

## Run requests in parallel

One worker runs one request at a time. Start several over the same module
and check one out per request; the module is compiled once.

```erlang
Workers = [element(2, wasmtime_instance_worker:start_link(Mod, Opts)) || _ <- lists:seq(1, 8)].
```

## Notes

- A deadline interrupts the guest on its own thread and the worker goes on
  to the next request. erlang_wasm kills its worker at the deadline; code
  that restarts a worker after a timeout still works, it just has nothing
  to restart.
- The deadline covers the wait for the worker. A request that waited past
  its own deadline answers `kind => timeout` without running.
- Host functions run in the worker process. A deadline cannot interrupt
  one; a worker that has not answered a second after the deadline is killed
  by the caller.
- A worker that is gone answers `kind => no_worker`; one that dies during a
  request, `kind => worker_died`. Neither raises.
- A module whose start section fails, or limits that are not valid, stop
  the worker with `{instantiate_failed, Error}`.
- `fresh` costs one `destroy/1` and one instantiation per request. With a
  pooled engine and a pre-initialized module that is about 0.1 ms; see
  [pre-initialization](preinit.md).
- `info/1` answers `#{served, isolation, name}`. `name` is a label and the
  process label in `observer`; the process is not registered under it.
