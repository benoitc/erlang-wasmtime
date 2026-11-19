# Hosting scripts

`wasmtime_script_worker` runs scripts your users send you, in JavaScript or
Python, each request in a fresh sandbox with its own directory, a deadline
and bounded output. You need it when tenants give you source code and not
compiled modules. An adapter tells the worker how to run one language; two
ship with the library and you can write your own. The functions are
erlang_wasm's `wasm_script_worker`.

## Get an interpreter

The interpreters are built by other projects and are not in the package.

| Language | Adapter | File |
|---|---|---|
| JavaScript | `wasmtime_javascript_command` | wasmedge-quickjs `wasmedge_quickjs.wasm`, release v0.5.0-alpha |
| Python | `wasmtime_python_command` | a CPython WASI command with its standard library inside the module |

```sh
curl -fsSLo qjs.wasm \
  https://github.com/second-state/wasmedge-quickjs/releases/download/v0.5.0-alpha/wasmedge_quickjs.wasm
```

## Start a worker and run a script

```erlang
{ok, _} = application:ensure_all_started(erlang_wasmtime),
{ok, W} = wasmtime_script_worker:start_link(wasmtime_javascript_command, #{path => "qjs.wasm"}),
{ok, #{result := #{~"answer" := 42}, stdout := Printed}} =
    wasmtime_script_worker:run(W, ~"export function main(c) { return {answer: c.value + 1}; }", #{
        ~"value" => 41
    }).
```

The script exports `main(context)`. The context and the result are JSON
values. What the script printed is in `stdout` and `stderr`.

Python, with the limits CPython needs:

```erlang
{ok, P} = wasmtime_script_worker:start_link(wasmtime_python_command, #{
    path => "python.wasm",
    limits => #{timeout => 60_000, max_memory_pages => 4096}
}),
{ok, #{result := 42}} = wasmtime_script_worker:run(P, ~"def main(c):\n    return c['value'] + 1\n", #{
    ~"value" => 41
}).
```

## Do not wait for the answer

```erlang
{ok, Ref} = wasmtime_script_worker:submit(W, Source, Context),
case wasmtime_script_worker:await(W, Ref, 100) of
    {error, #{kind := still_running}} -> ok = wasmtime_script_worker:cancel(W, Ref);
    Outcome -> Outcome
end.
```

`await/3`'s timeout bounds your wait, not the request. `cancel/2` is what
stops a script.

## Read a failure

Every failure is `{error, #{class, kind, message, ctx}}`
(`wasmtime_worker_error`).

| `class` | `kind` | Meaning |
|---|---|---|
| `adapter` | `adapter_failure`, `ctx.code` `exception` | the script raised; the message is in `message` |
| `adapter` | `adapter_failure`, `ctx.code` `no_entry_point`, `no_result`, `bad_result` | no `main`, or a result that is not JSON |
| `adapter` | `exit` | the interpreter exited with `ctx.code` |
| `worker` | `timeout` | the request ran past `timeout`; the script was interrupted |
| `worker` | `cancelled` | `cancel/2`, or the process that submitted died |
| `worker` | `output_limit` | the script wrote more than `max_output_bytes` |
| `worker` | `insufficient_limit` | the request needs more than the worker's limits; `ctx.limit` names it |
| `worker` | `busy` | the worker is running another request |
| `worker` | `crashed` | the adapter crashed |
| `runtime` | `runtime_failure` | a trap or a link error; the runtime's error is in `ctx.error` |

## Set the limits

`limits` in the worker's options is merged over these defaults
(`wasmtime_script_worker:default_limits/0`):

| Limit | Default | Bounds |
|---|---:|---|
| `timeout` | 5 s | one request, wall clock; `infinity` to rely on `cancel/2` |
| `max_memory_pages` | 256 | the guest's linear memory, 16 MB |
| `max_output_bytes` | 1 MiB | stdout and stderr, each |
| `max_request_bytes` | 1 MiB | the source and the encoded context |
| `max_staged_bytes` | 8 MiB | the files the adapter stages for the request |
| `max_staged_files` | 64 | how many |
| `fuel` | none | instructions; the engine must be compiled with `compile => #{fuel => true}` |

An adapter never raises a limit for you: a request that needs more answers
`insufficient_limit`.

## Say where request files go

```erlang
%% sys.config
[{erlang_wasmtime, [{scratch_roots, #{scratch => "/var/lib/myapp/scratch"}}]}].
```

Each request gets a directory `req-...` under the root, removed when the
request ends, whatever its outcome. Without `scratch_roots` the root is a
directory in the user cache that only this node uses. A worker picks a root
with `root => Name`.

## Run several at once

A worker runs one request at a time. Start several over the same engine;
the engine is compiled once.

```erlang
Pool = [element(2, wasmtime_script_worker:start_link(wasmtime_javascript_command, Opts))
        || _ <- lists:seq(1, 8)].
```

## Write an adapter

An adapter is a module with the `wasmtime_worker_adapter` behaviour: it
loads what it runs (`artifact/1`), says what a request needs
(`requirements/2`), stages files and names the calls to make (`prepare/3`),
says what each call's result means (`classify/2`) and turns what happened
into an answer (`decode/2`). `src/wasmtime_javascript_command.erl` is 150
lines and a good start; `test/wasmtime_test_adapter.erl` runs plain exports
without a script.

What differs from an erlang_wasm adapter: WASI is an instantiate option
here, so `prepare/3` answers `options => #{wasi => ...}` in the execution
spec, without `stdout` and `stderr`, which the worker captures.

## Notes

- Each request runs the interpreter from its start. The adapters that start
  it once and restore a snapshot per request (erlang_wasm's `wasm_javascript`,
  `wasm_python`, `wasm_lua`) are not here yet; see [features](features.md),
  "Deferred". For a pre-initialized CPython per request today, see
  [pre-initialization](preinit.md).
- The script sees one read-only directory with its source and context, no
  environment, no network, and only the monotonic clock.
- A script that floods its output runs to its deadline; the answer is then
  `timeout`, not `output_limit`. `output_limit` is for a script that ended
  after writing too much.
- A node that crashes during a request leaves that request's directory.
  Nothing sweeps it at the next start: empty the root yourself if that
  matters. erlang_wasm's reaper and its journal are not ported.
- The JavaScript bootstrap is written for wasmedge-quickjs, which imports
  WasmEdge's socket functions; the adapter binds them to functions that
  answer `ENOSYS`.
- A writable mount needs `trusted => true` in the worker's options. The
  shipped adapters mount nothing writable.
