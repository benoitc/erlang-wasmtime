-module(wasmtime_javascript_command).
-moduledoc """
Run JavaScript that arrives at request time, through the `script_v1` profile:
erlang_wasm's `wasm_javascript_command`.

The interpreter is QuickJS compiled to WebAssembly as a WASI command.
It is started again for every request, in a fresh instance.

```erlang
{ok, W} = wasmtime_script_worker:start_link(wasmtime_javascript_command, #{path => "qjs.wasm"}),
{ok, #{result := #{~"answer" := 42}}} =
    wasmtime_script_worker:run(W, ~"export function main(c) { return {answer: c.value + 1}; }", #{~"value" => 41}).
```

It stages three files into one read-only mount and runs the engine over
them: the profile's bootstrap, the source as `/main.js` and the context
as `/context.json`. The bootstrap loads the source by absolute path, so
nothing the script writes reaches a module the host did not put there. The
guest gets no other directory, no environment, and only the monotonic
clock.

The bootstrap is written for wasmedge-quickjs (`wasmedge_quickjs.wasm`,
release v0.5.0-alpha), the build erlang_wasm uses. It imports WasmEdge's
socket functions, which are bound here to functions answering `ENOSYS`.

`path` in the worker's options names the engine. It is loaded through
`wasmtime:load/1`, so workers over the same file share one compiled module,
and the `erlang_wasmtime` application must be started.
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

-define(DEFAULT_SOURCE, ~"export function main(context) { return context; }").

artifact(#{path := Path} = Opts) ->
    maybe
        {ok, Bytes} ?= file:read_file(Path),
        {ok, Module} ?= wasmtime:load(Bytes, maps:get(compile, Opts, #{})),
        {ok, #{
            module => Module, boot => wasmtime_script_v1:boot(js), stubs => socket_stubs(Module)
        }}
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
    {error, wasmtime_worker_error:adapter(adapter_failure, ~"no `path` to a QuickJS build", #{})}.

%% wasmedge-quickjs, the build the bootstrap is written for, imports
%% WasmEdge's socket functions from the WASI module, which Wasmtime does not
%% have. Each one the engine imports is bound to a function that answers
%% ENOSYS: the script has no network either way.
-define(WASMEDGE_SOCKETS, [
    ~"sock_open",
    ~"sock_bind",
    ~"sock_connect",
    ~"sock_listen",
    ~"sock_setsockopt",
    ~"sock_getlocaladdr",
    ~"sock_getpeeraddr",
    ~"sock_getaddrinfo",
    %% these four exist in WASI with other signatures than WasmEdge's
    ~"sock_accept",
    ~"sock_recv",
    ~"sock_send",
    ~"sock_shutdown"
]).
-define(ENOSYS, 52).

socket_stubs(Module) ->
    #{
        {Wasi, Name} => fun(_Inst, _Args) -> {ok, [?ENOSYS]} end
     || {~"wasi_snapshot_preview1" = Wasi, Name, func} <- wasmtime:imports(Module),
        lists:member(Name, ?WASMEDGE_SOCKETS)
    }.

requirements(Request, #{boot := Boot}) when is_map(Request) ->
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = wasmtime_script_v1:encode_context(maps:get(context, Request, #{})),
    {ok, #{
        min_timeout => 1_000,
        min_memory_pages => 64,
        request_bytes => byte_size(Source) + byte_size(Context),
        staged_bytes => byte_size(Boot) + byte_size(Source) + byte_size(Context),
        staged_files => 3,
        mounts => #{ro => #{guest_path => ~"/", mode => read}}
    }};
requirements(_Request, _Artifact) ->
    {error, wasmtime_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(Request, #{module := Module, boot := Boot, stubs := Stubs}, #{
    stage := Stage, mounts := Mounts
}) ->
    Marker = wasmtime_script_v1:marker(),
    Source = maps:get(source, Request, ?DEFAULT_SOURCE),
    Context = wasmtime_script_v1:encode_context(maps:get(context, Request, #{})),
    Files = [{~"_boot.js", Boot}, {~"main.js", Source}, {~"context.json", Context}],
    case wasmtime_script_v1:stage_all(Stage, Files) of
        {error, Error} ->
            {error, Error, #{marker => Marker}};
        ok ->
            #{ro := #{host_dir := Dir}} = Mounts,
            Wasi = #{
                args => [~"qjs", ~"/_boot.js", Marker],
                env => [],
                dirs => [{~"/", Dir, read}],
                clocks => monotonic
            },
            {ok,
                #{
                    mode => command,
                    module => Module,
                    imports => #{bindings => Stubs},
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
                source => ~"export function main(c) { return {answer: c.value + 1}; }",
                context => #{~"value" => 41}
            },
            failure => #{source => ~"export function main(c) { throw new Error('boom'); }"},
            runaway => #{source => ~"export function main(c) { for (;;) {} }"},
            state_change => #{
                source =>
                    ~"export function main(c) { globalThis.n = (globalThis.n || 0) + 1; return {n: globalThis.n}; }"
            }
        },
        by_capability => #{}
    }.

%% A command ends by exiting: WASI's exit is an error of class `exit` here.
classify({ok, _Values}, _State) -> continue;
classify({error, #{class := exit, status := Code}}, _State) -> {stop, {exited, Code}};
classify({error, _}, _State) -> {stop, trapped}.
