-module(wasmtime_wasi_config).
-moduledoc false.
%% The `wasi` option of wasmtime:instantiate/3: what the NIF reads, and what
%% is done in Erlang around it (output sinks, a seeded or withheld random).
%% The accepted values are this library's and erlang_wasm's.

-export([options/2, deliver/3, imports/1, take_imports/2]).

-export_type([sinks/0]).

-type sink() :: pid() | atom() | fun((binary()) -> term()).
-type sinks() :: #{stdout => sink(), stderr => sink()}.

-define(DEFAULT_OUTPUT_LIMIT, 16 * 1024 * 1024).
%% erlang_wasm's bound on the body of an HTTP request and of a response
-define(DEFAULT_HTTP_BODY_LIMIT, 8 * 1024 * 1024).
%% what wasmtime_wasi:imports/1 puts in an import map
-define(MARKER, {~"$wasi", ~"config"}).
-define(PREVIEW1, ~"wasi_snapshot_preview1").
%% random_get's errno answers
-define(ESUCCESS, 0).
-define(EFAULT, 21).
-define(ENOTCAPABLE, 76).
%% random bytes generated and written at a time
-define(RANDOM_CHUNK, 65536).

-spec imports(map()) -> map().
imports(Config) when is_map(Config) -> #{?MARKER => {wasi_config, Config}}.

%% The configuration an import map from wasmtime_wasi:imports/1 carries moves
%% to the `wasi` option.
-spec take_imports(map(), map()) -> {ok, map(), map()} | wasmtime:error().
take_imports(#{?MARKER := {wasi_config, _}}, #{wasi := _}) ->
    wasmtime_error:new(
        link, badarg, ~"give the WASI configuration once: as `wasi` or as imports"
    );
take_imports(#{?MARKER := {wasi_config, Config}} = Imports, Opts) ->
    {ok, maps:remove(?MARKER, Imports), Opts#{wasi => Config}};
take_imports(Imports, Opts) ->
    {ok, Imports, Opts}.

%% {ok, NifOptions, #{sinks, imports}}: `imports` are host functions that
%% replace WASI's.
-spec options(none | map(), module | component) ->
    {ok, none | map(), #{
        sinks := sinks(),
        imports := map(),
        transport := none | wasmtime_http_transport:settings()
    }}
    | wasmtime:error().
options(none, _Kind) ->
    {ok, none, #{sinks => #{}, imports => #{}, transport => none}};
options(Wasi, Kind) when is_map(Wasi) ->
    Refused = refused_keys(Wasi, Kind),
    Clocks = clocks(maps:get(clocks, Wasi, all)),
    Random = random(maps:get(random, Wasi, strong), Kind),
    Grants = [{Key, wasmtime_net:grant(maps:get(Key, Wasi, none))} || Key <- [network, http]],
    Bad =
        Refused ++
            [Key || {_, {unsupported, Keys}} <- Grants, Key <- Keys] ++
            [clocks || Clocks =:= unsupported] ++
            [random || Random =:= unsupported] ++
            [Key || Key <- [stdout, stderr], stdio(Key, Wasi) =:= unsupported],
    case Bad of
        [] ->
            built(Wasi, maps:merge(nif_options(Wasi, Clocks), granted(Grants)), Random);
        _ ->
            wasmtime_error:new(
                link, unsupported_option, ~"this runtime does not support the option", #{
                    keys => Bad
                }
            )
    end.

refused_keys(Wasi, Kind) ->
    Known = [args, env, dirs, stdin, stdout, stderr, output_limit, clocks, network, http, random],
    %% only a component has a place for these
    Component = [initial_cwd, http_max_field_bytes, http_max_body_bytes] ++ transport_keys(),
    Taken =
        case Kind of
            component -> Known ++ Component;
            module -> Known
        end,
    %% `net => none` is erlang_wasm's default, which is what happens anyway
    maps:keys(maps:without(Taken, maps:filter(fun(Key, V) -> {Key, V} =/= {net, none} end, Wasi))).

granted(Grants) -> maps:from_list([{Key, Grant} || {Key, {ok, Grant}} <- Grants]).

%% The NIF's options, and what is done in Erlang around them.
built(Wasi, Options, Random) ->
    Sinks = maps:from_list([
        {Key, Sink}
     || Key <- [stdout, stderr], {sink, Sink} <- [stdio(Key, Wasi)]
    ]),
    Transport = transport(Wasi),
    {ok, Options#{transport => Transport =/= none}, #{
        sinks => Sinks, imports => Random, transport => Transport
    }}.

transport_keys() -> [http_transport, http_tls].

%% The module that sends the component's requests, when it may send any.
transport(#{http_transport := Module} = Wasi) ->
    case maps:get(http, Wasi, none) of
        none ->
            none;
        _ ->
            Max =
                case byte_limit(http_max_body_bytes, Wasi, ?DEFAULT_HTTP_BODY_LIMIT) of
                    invalid -> ?DEFAULT_HTTP_BODY_LIMIT;
                    N -> N
                end,
            wasmtime_http_transport:settings(Module, maps:get(http_tls, Wasi, []), Max)
    end;
transport(_) ->
    none.

nif_options(Wasi, Clocks) ->
    #{
        args =>
            case maps:get(args, Wasi, []) of
                inherit -> inherit;
                Args -> [bin(A) || A <- Args]
            end,
        env =>
            case maps:get(env, Wasi, []) of
                inherit -> inherit;
                Env when is_map(Env) -> [{bin(K), bin(V)} || K := V <- Env];
                Env -> [{bin(K), bin(V)} || {K, V} <- Env]
            end,
        dirs => [dir(D) || D <- maps:get(dirs, Wasi, [])],
        stdin => stdin(maps:get(stdin, Wasi, none)),
        stdout => mode(stdio(stdout, Wasi)),
        stderr => mode(stdio(stderr, Wasi)),
        output_limit => maps:get(output_limit, Wasi, ?DEFAULT_OUTPUT_LIMIT),
        clocks => Clocks,
        initial_cwd =>
            case maps:find(initial_cwd, Wasi) of
                {ok, Cwd} -> bin(Cwd);
                error -> undefined
            end,
        http_max_field_bytes => byte_limit(http_max_field_bytes, Wasi, 0),
        http_max_body_bytes => byte_limit(http_max_body_bytes, Wasi, default_body_limit())
    }.

%% A byte limit; 0 keeps what Wasmtime does by itself. Anything but a positive
%% integer is passed on as the NIF refuses it.
byte_limit(Key, Wasi, Default) ->
    case maps:find(Key, Wasi) of
        {ok, N} when is_integer(N), N > 0 -> N;
        {ok, _} -> invalid;
        error -> Default
    end.

%% A library without this project's patches cannot bound a body.
default_body_limit() ->
    case wasmtime:features() of
        #{wasi_limits := true} -> ?DEFAULT_HTTP_BODY_LIMIT;
        #{wasi_limits := false} -> 0
    end.

dir({Guest, Host}) ->
    dir({Guest, Host, read});
dir({Guest, Host, Access}) when Access =:= read; Access =:= write ->
    {bin(Guest), bin(Host), Access}.

%% `all` or `monotonic`, also as erlang_wasm's list of clocks.
clocks(all) ->
    all;
clocks(monotonic) ->
    monotonic;
clocks(List) when is_list(List) ->
    case lists:usort(List) of
        [monotonic] -> monotonic;
        [monotonic, realtime] -> all;
        _ -> unsupported
    end.

stdin(none) -> none;
stdin(inherit) -> inherit;
stdin(stream) -> stream;
stdin({file, Path}) -> {file, bin(Path)};
stdin({binary, Bytes}) -> {binary, iolist_to_binary(Bytes)};
stdin(Bytes) when is_binary(Bytes) -> {binary, Bytes}.

%% What one of stdout and stderr asks for: a mode of the NIF's, or a sink
%% that is fed from the streamed bytes.
stdio(Key, Wasi) ->
    case maps:get(Key, Wasi, none) of
        Mode when
            Mode =:= none; Mode =:= inherit; Mode =:= capture; Mode =:= stream
        ->
            {mode, Mode};
        {file, Path} ->
            {mode, {file, bin(Path)}};
        Pid when is_pid(Pid) ->
            {sink, Pid};
        Fun when is_function(Fun, 1) ->
            {sink, Fun};
        Device when is_atom(Device) ->
            %% an atom nobody answers to would swallow the output
            Known = Device =:= standard_io orelse Device =:= standard_error,
            case Known orelse whereis(Device) =/= undefined of
                true -> {sink, Device};
                false -> unsupported
            end
    end.

mode({mode, Mode}) -> Mode;
mode({sink, _}) -> stream.

%% Hand bytes to a sink, in the process that is waiting for the call, as
%% erlang_wasm does. A sink that fails loses the bytes, not the call.
-spec deliver(sinks(), stdout | stderr, binary()) -> ok.
deliver(Sinks, Which, Bytes) ->
    try
        case map_get(Which, Sinks) of
            Pid when is_pid(Pid) -> Pid ! {wasi_output, self(), Bytes};
            Fun when is_function(Fun, 1) -> Fun(Bytes);
            Device -> io:put_chars(Device, Bytes)
        end
    of
        _ -> ok
    catch
        _:_ -> ok
    end.

%% The host functions that take WASI's place for `random`. Only a core module
%% can have them: a component's WASI cannot be replaced.
random(strong, _Kind) ->
    #{};
random(none, module) ->
    #{{?PREVIEW1, ~"random_get"} => fun(_, [_, _]) -> {ok, [?ENOTCAPABLE]} end};
random({seed, Seed}, module) when is_integer(Seed) ->
    Key = {?MODULE, random, make_ref()},
    #{{?PREVIEW1, ~"random_get"} => fun(Ctx, [Ptr, Len]) -> seeded(Key, Seed, Ctx, Ptr, Len) end};
random(_, _) ->
    unsupported.

%% erlang_wasm's seeded source: one generator per instance, carried from call
%% to call. It lives in the process that serves the host calls.
seeded(Key, Seed, Ctx, Ptr0, Len0) ->
    Ptr = Ptr0 band 16#FFFFFFFF,
    Len = Len0 band 16#FFFFFFFF,
    {ok, Pages} = wasmtime:memory_size(Ctx),
    %% checked before a byte is made, so a request that cannot land costs
    %% nothing
    case Ptr + Len =< Pages * 65536 of
        false ->
            {ok, [?EFAULT]};
        true ->
            State =
                case get(Key) of
                    undefined -> rand:seed_s(exsss, {Seed, Seed, Seed});
                    Kept -> Kept
                end,
            put(Key, fill(Ctx, Ptr, Len, State)),
            {ok, [?ESUCCESS]}
    end.

fill(_Ctx, _Ptr, 0, State) ->
    State;
fill(Ctx, Ptr, Len, State) ->
    N = min(Len, ?RANDOM_CHUNK),
    {Bytes, Next} = rand:bytes_s(N, State),
    ok = wasmtime:write_memory(Ctx, Ptr, Bytes),
    fill(Ctx, Ptr + N, Len - N, Next).

bin(B) when is_binary(B) -> B;
bin(L) -> unicode:characters_to_binary(L).
