-module(wasmtime_wasi_preview2).
-moduledoc """
Run a `wasi:cli/command` component, bytes in and bytes out: erlang_wasm's
`wasi_preview2:run_command`.

```erlang
{ok, Component} = file:read_file("upper.wasm"),
{ok, #{stdout := ~"HELLO", exit_code := 0}} =
    wasmtime_wasi_preview2:run_command(Component, ~"hello").
```

The component may use WASI 0.2 or 0.3. It is given what you name in the
options and nothing else.
""".

-export([run_command/2, run_command/3]).

-export_type([command_options/0, command_result/0]).

-doc """
- `args`, `env`: what the program sees.
- `preopen => Dir` (read-only unless `writable => true`) mounts one directory
  at `/`; `preopens => [{Guest, Dir, Writable}]` names several.
- `network`: `all`, or a grant as the `wasi` option's: sockets, and
  `wasi:http` requests to the addresses its `connect` rules allow, on a
  library that has it.
- `initial_cwd`, `resource_limit`.
- `http_max_body_bytes`: the bound on a request's body and a response's,
  8 MiB when left out.
- `timeout`, `fuel`, `max_memory_pages`: the limits of `wasmtime_limits`.
- `compile => true`: do not keep the component in the module cache.

erlang_wasm's `stdout_limit` and `stdin_dir` are refused with
`kind => unsupported_option`.
""".
-type command_options() :: #{
    args => [binary()],
    env => [{binary(), binary()}],
    preopen => file:filename_all(),
    writable => boolean(),
    preopens => [{binary(), file:filename_all(), boolean()}],
    network => all | map(),
    initial_cwd => binary(),
    http_max_body_bytes => pos_integer(),
    resource_limit => non_neg_integer() | infinity,
    compile => boolean(),
    timeout => timeout(),
    fuel => pos_integer() | infinity,
    max_memory_pages => non_neg_integer() | infinity
}.

-type command_result() ::
    {ok, #{stdout := binary(), stderr := binary(), exit_code := integer()}}
    | {error, no_run_export | wasmtime_error:error()}.

-doc #{equiv => run_command(Component, Stdin, #{})}.
-spec run_command(binary() | wasmtime_component:prepared(), binary()) -> command_result().
run_command(Component, Stdin) -> run_command(Component, Stdin, #{}).

-doc """
Run the component with `Stdin` on its standard input and answer what it wrote
and its exit status. WASI 0.2 reports success or failure only, so a failing
program's status is 1.
""".
-spec run_command(binary() | wasmtime_component:prepared(), binary(), command_options()) ->
    command_result().
run_command(Component, Stdin, Options) when is_binary(Stdin), is_map(Options) ->
    Known =
        [args, env, preopen, writable, preopens, network, initial_cwd, compile] ++
            [http_max_body_bytes],
    Limits = [timeout, fuel, max_memory_pages, resource_limit],
    case maps:keys(maps:without(Known ++ Limits, Options)) of
        [] -> run(Component, Stdin, Options, maps:with(Limits, Options));
        Keys -> unsupported(Keys)
    end.

unsupported(Keys) ->
    wasmtime_error:new(link, unsupported_option, ~"this runtime does not support the option", #{
        keys => Keys
    }).

run(Component, Stdin, Options, Limits) ->
    Grant = maps:get(network, Options, none),
    Wasi = (maps:with([initial_cwd, http_max_body_bytes], Options))#{
        args => maps:get(args, Options, []),
        env => maps:get(env, Options, []),
        dirs => mounts(Options),
        stdin => {binary, Stdin},
        stdout => capture,
        stderr => capture,
        network => Grant,
        http => http(Grant)
    },
    maybe
        {ok, Module} ?= module(Component, Options),
        %% the cache claim goes back however the run ends
        try
            run_module(Module, Limits#{wasi => Wasi})
        after
            ok = release(Component, Options, Module)
        end
    end.

run_module(Module, Opts) ->
    maybe
        {ok, Inst} ?= wasmtime:instantiate(Module, #{}, Opts),
        Result = wasmtime:run(Inst),
        {ok, {Out, Err, _Dropped}} = wasmtime:read_output(Inst),
        ok = wasmtime:destroy(Inst),
        outcome(Result, #{stdout => Out, stderr => Err})
    end.

outcome(ok, Output) ->
    {ok, Output#{exit_code => 0}};
outcome({error, #{ctx := #{wasi_exit := Code}}}, Output) ->
    {ok, Output#{exit_code => Code}};
outcome({error, #{kind := unknown_export}}, _) ->
    {error, no_run_export};
outcome({error, _} = Error, _) ->
    Error.

%% A network grant covers HTTP too, where the library can send requests.
http(Grant) ->
    case wasmtime:features() of
        #{wasi_http := true} -> Grant;
        #{wasi_http := false} -> none
    end.

mounts(#{preopens := Mounts}) ->
    [{Guest, Dir, access(Writable)} || {Guest, Dir, Writable} <- Mounts];
mounts(#{preopen := Dir} = Options) ->
    [{~"/", Dir, access(maps:get(writable, Options, false))}];
mounts(_) ->
    [].

access(true) -> write;
access(false) -> read.

%% Cached while the application runs, so the same bytes compile once.
module({prepared, Module}, _) ->
    {ok, Module};
module(Bytes, Options) ->
    case cached(Options) of
        true -> wasmtime:load(Bytes);
        false -> wasmtime:compile(Bytes)
    end.

release({prepared, _}, _, _) ->
    ok;
release(_, Options, Module) ->
    case cached(Options) of
        true -> wasmtime:unload(Module);
        false -> ok
    end.

cached(Options) ->
    not maps:get(compile, Options, false) andalso whereis(wasmtime_module_cache) =/= undefined.
