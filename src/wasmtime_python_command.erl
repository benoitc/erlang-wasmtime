-module(wasmtime_python_command).
-moduledoc """
Run Python that arrives at request time, through the `script_v1` profile:
erlang_wasm's `wasm_python_command`.

The interpreter is CPython compiled to WebAssembly as a WASI command.
It is started again for every request, in a fresh instance.

```erlang
{ok, W} = wasmtime_script_worker:start_link(wasmtime_python_command, #{path => "python.wasm"}),
{ok, #{result := #{~"answer" := 42}}} =
    wasmtime_script_worker:run(W, ~"def main(c):\n    return {\"answer\": c[\"value\"] + 1}\n", #{~"value" => 41}).
```

It stages three files into one read-only mount and runs the engine over
them: the profile's bootstrap, the source as `/main.py` and the context
as `/context.json`. The bootstrap loads the source by absolute path, so
nothing the script writes reaches a module the host did not put there. The
guest gets no other directory, no environment, and only the monotonic
clock.

`path` in the worker's options names the engine. It is loaded through
`wasmtime:load/1`, so workers over the same file share one compiled module,
and the `erlang_wasmtime` application must be started.

CPython needs more than the worker's defaults: its memory (512 pages at
least) and its start-up time. Raise `max_memory_pages` and `timeout` in the
worker's `limits`; the adapter never raises a limit for you. The build must
carry its standard library inside the module, since the guest sees no other
directory.
""".

-behaviour(wasmtime_worker_adapter).

-export([
    artifact/1,
    requirements/2,
    prepare/3,
    decode/2,
    cleanup/1,
    capabilities/1,
    conformance_fixtures/1,
    classify/2
]).

-define(DEFAULT_SOURCE, ~"def main(context):\n    return context\n").

artifact(#{path := Path} = Opts) ->
    maybe
        {ok, Bytes} ?= file:read_file(Path),
        {ok, Module} ?= wasmtime:load(Bytes, maps:get(compile, Opts, #{})),
        {ok, #{module => Module, boot => wasmtime_script_v1:boot(py)}}
    else
        {error, #{} = Error} ->
            {error, wasmtime_worker_error:runtime(Error)};
        {error, Reason} ->
            {error,
                wasmtime_worker_error:adapter(adapter_failure, ~"cannot read the engine", #{
                    path => unicode:characters_to_binary(Path), reason => Reason
                })}
    end;
artifact(_Opts) ->
    {error, wasmtime_worker_error:adapter(adapter_failure, ~"no `path` to a CPython build", #{})}.

requirements(Request, #{boot := Boot}) when is_map(Request) ->
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = wasmtime_script_v1:encode_context(maps:get(context, Request, #{})),
    {ok, #{
        min_timeout => 10_000,
        min_memory_pages => 512,
        request_bytes => byte_size(Source) + byte_size(Context),
        staged_bytes => byte_size(Boot) + byte_size(Source) + byte_size(Context),
        staged_files => 3,
        mounts => #{ro => #{guest_path => ~"/", mode => read}}
    }};
requirements(_Request, _Artifact) ->
    {error, wasmtime_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{module := Module, boot := Boot}, #{stage := Stage, mounts := Mounts}) ->
    Marker = wasmtime_script_v1:marker(),
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = wasmtime_script_v1:encode_context(maps:get(context, Request, #{})),
    Files = [{~"_boot.py", Boot}, {~"main.py", Source}, {~"context.json", Context}],
    case wasmtime_script_v1:stage_all(Stage, Files) of
        {error, Error} ->
            {error, Error, #{marker => Marker}};
        ok ->
            #{ro := #{host_dir := Dir}} = Mounts,
            Wasi = #{
                args => [~"python", ~"-I", ~"-B", ~"-u", ~"/_boot.py", Marker],
                env => [],
                dirs => [{~"/", Dir, read}],
                clocks => monotonic
            },
            {ok,
                #{
                    mode => command,
                    module => Module,
                    imports => #{bindings => #{}},
                    options => #{wasi => Wasi},
                    invoke => [{call, ~"_start", []}]
                },
                #{marker => Marker}}
    end.

decode(Result, #{marker := Marker}) ->
    wasmtime_script_v1:combined_outcome(Result, Marker).

cleanup(_State) -> ok.

capabilities(_Artifact) ->
    #{
        execution => command,
        input_channels => [files],
        result_channels => [framed_stream],
        snapshots => unsupported,
        wasi => true
    }.

conformance_fixtures(_Artifact) ->
    #{
        base => #{
            echo => #{
                source => ~"def main(c):\n    return {\"answer\": c[\"value\"] + 1}\n",
                context => #{~"value" => 41}
            },
            failure => #{source => ~"def main(c):\n    raise RuntimeError(\"boom\")\n"},
            runaway => #{source => ~"def main(c):\n    while True:\n        pass\n"},
            state_change => #{source => state_change_source()}
        },
        by_capability => #{}
    }.

%% A command ends by exiting: WASI's exit is an error of class `exit` here.
state_change_source() ->
    <<
        "import builtins\n",
        "def main(c):\n",
        "    builtins.n = getattr(builtins, \"n\", 0) + 1\n",
        "    return {\"n\": builtins.n}\n"
    >>.

classify({ok, _Values}, _State) -> continue;
classify({error, #{class := exit, status := Code}}, _State) -> {stop, {exited, Code}};
classify({error, _}, _State) -> {stop, trapped}.
