-module(wasmtime_worker_adapter).
-moduledoc """
The behaviour an adapter implements: what teaches `wasmtime_script_worker`
one language. erlang_wasm's `wasm_worker_adapter`, with the same callbacks.

The worker knows about modules, calls, deadlines, request directories and
bounded output. It does not know what a script is, what JSON is, or that
an entry point might be called `main`: the adapter supplies that.

```erlang
-module(my_adapter).
-behaviour(wasmtime_worker_adapter).
-export([artifact/1, requirements/2, prepare/3, decode/2, cleanup/1,
         capabilities/1, conformance_fixtures/1, classify/2]).
```

What differs from erlang_wasm, because WASI is an option here and not a
set of imports: `prepare/3` answers the WASI configuration in the
execution spec's `options`, and the worker captures stdout and stderr
itself, so there are no channels in the environment. See
[scripting](scripting.md).
""".

-export_type([
    artifact/0,
    request/0,
    adapter_state/0,
    outcome/0,
    mount/0,
    env/0,
    execution_spec/0,
    execution_result/0,
    requirements/0,
    capabilities/0,
    fixtures/0
]).

-doc "Whatever the adapter loaded once, when the worker started. Opaque to the worker.".
-type artifact() :: term().
-doc "One unit of tenant work. The worker never reads inside it.".
-type request() :: term().
-doc "Whatever `prepare/3` needs `decode/2` and `cleanup/1` to receive.".
-type adapter_state() :: term().
-doc "What a request answers with.".
-type outcome() :: {ok, term()} | {error, wasmtime_worker_error:worker_error()}.

-doc "One host directory of the request, preopened at `guest_path` with one mode.".
-type mount() :: #{guest_path := binary(), host_dir := binary(), mode := read | write}.

-doc """
What `prepare/3` is handed. `mounts` exist already. `limits` are the
effective ones. `stage` writes a file under a mount, within
`max_staged_bytes` and `max_staged_files`; a path that leaves the mount is
`kind => bad_stage_path`. `deadline` is in monotonic milliseconds.
""".
-type env() :: #{
    mounts := #{atom() => mount()},
    deadline := integer() | infinity,
    limits := map(),
    stage := fun((atom(), binary(), iodata()) -> ok | {error, wasmtime_worker_error:worker_error()})
}.

-doc """
What the worker runs: a module, its imports, the instantiate options (the
`wasi` configuration, without `stdout` and `stderr`, which the worker
captures), and the calls to make in order.
""".
-type execution_spec() :: #{
    mode := command | reactor,
    module := wasmtime:module_ref(),
    imports := #{bindings := wasmtime:imports()},
    options => wasmtime:options(),
    invoke := [{call, binary(), [term()]}, ...]
}.

-doc "What happened, still uninterpreted. `error` is the runtime's error of a trap.".
-type execution_result() :: #{
    outcome := returned | trapped | exited,
    values := [term()],
    exit := undefined | integer(),
    channels := #{stdout := binary(), stderr := binary()},
    error := undefined | map()
}.

-doc "What this request needs, and what staging it costs.".
-type requirements() :: #{
    min_timeout := pos_integer(),
    min_memory_pages := non_neg_integer(),
    request_bytes := non_neg_integer(),
    staged_bytes := non_neg_integer(),
    staged_files := non_neg_integer(),
    mounts := #{atom() => #{guest_path := binary(), mode := read | write}}
}.

-doc "What the adapter can do, for a conformance test to know what to ask.".
-type capabilities() :: #{
    execution := command | reactor | both,
    input_channels := [typed_args | stdin | files | custom_import],
    result_channels := [typed_result | custom_import | framed_stream],
    snapshots := unsupported | #{version := binary()},
    wasi := boolean()
}.

-doc "Requests a conformance test submits without reading them.".
-type fixtures() :: #{
    base := #{
        echo := request(), failure := request(), runaway := request(), state_change := request()
    },
    by_capability := #{atom() => request()}
}.

-doc "Load whatever this adapter runs, once, when the worker starts. Gets the worker's options.".
-callback artifact(Opts :: map()) ->
    {ok, artifact()} | {error, wasmtime_worker_error:worker_error()}.

-doc "What this request needs and costs, before anything is created.".
-callback requirements(request(), artifact()) ->
    {ok, requirements()} | {error, wasmtime_worker_error:worker_error()}.

-doc "Build the thing to run. The mounts exist; the limits are final.".
-callback prepare(request(), artifact(), env()) ->
    {ok, execution_spec(), adapter_state()}
    | {error, wasmtime_worker_error:worker_error(), adapter_state()}.

-doc "Turn what happened into an answer.".
-callback decode(execution_result(), adapter_state()) -> outcome().

-doc "Release whatever `prepare/3` acquired. Runs after the request, whatever its outcome.".
-callback cleanup(adapter_state()) -> ok.

-doc "What this adapter can do.".
-callback capabilities(artifact()) -> capabilities().

-doc "Requests for a conformance test.".
-callback conformance_fixtures(artifact()) -> fixtures().

-doc """
Called after every call, success or error: the worker interprets none of
them. A WASI exit arrives as `{error, #{ctx := #{wasi_exit := N}}}`, and
only the adapter knows whether that ends the request.
""".
-callback classify({ok, [term()] | term()} | {error, map()}, adapter_state()) ->
    continue | {stop, returned | trapped | {exited, integer()}}.
