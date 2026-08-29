%% The binding on a runtime-only Wasmtime: no compiler, maybe no WASI.
%% Modules come precompiled from scripts/precompile-fixtures.escript, run on
%% a full build of the same machine; WASMTIME_CWASM_DIR points at them.
-module(wasmtime_runtime_only_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    features_shape/1,
    compile_unavailable/1,
    serialize_unavailable/1,
    wasi_by_features/1,
    deserialize_and_call/1,
    deserialize_garbage/1,
    host_functions/1,
    memory_access/1,
    interrupt/1,
    streams/1
]).

all() ->
    [
        features_shape,
        compile_unavailable,
        serialize_unavailable,
        wasi_by_features,
        deserialize_and_call,
        deserialize_garbage,
        host_functions,
        memory_access,
        interrupt,
        streams
    ].

init_per_suite(Config) ->
    case wasmtime:features() of
        #{compiler := true} ->
            {skip, "full build: the main suites cover it"};
        _ ->
            case os:getenv("WASMTIME_CWASM_DIR") of
                false ->
                    {skip,
                        "set WASMTIME_CWASM_DIR to fixtures from scripts/precompile-fixtures.escript"};
                Dir ->
                    [{cwasm, Dir} | Config]
            end
    end.

end_per_suite(_) -> ok.

load(Config, Name) ->
    {ok, Pre} = file:read_file(filename:join(?config(cwasm, Config), Name ++ ".cwasm")),
    {ok, Mod} = wasmtime:deserialize(Pre),
    Mod.

features_shape(_) ->
    #{compiler := false, wat := Wat, wasi := Wasi} = wasmtime:features(),
    true = is_boolean(Wat) andalso is_boolean(Wasi),
    ok.

compile_unavailable(_) ->
    {error, #{class := compile, kind := unavailable, message := Msg}} =
        wasmtime:compile(<<0, "asm", 1, 0, 0, 0>>),
    ?assertMatch({_, _}, binary:match(Msg, ~"deserialize")),
    {error, #{class := compile, kind := unavailable}} = wasmtime:compile({wat, ~"(module)"}),
    ok.

serialize_unavailable(Config) ->
    {error, #{class := compile, kind := unavailable}} = wasmtime:serialize(load(Config, "basic")),
    ok.

wasi_by_features(Config) ->
    Mod = load(Config, "wasi"),
    Out = filename:join(?config(priv_dir, Config), "out.txt"),
    case wasmtime:features() of
        #{wasi := true} ->
            {ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{stdout => {file, Out}}}),
            {ok, []} = wasmtime:call(Inst, ~"_start", []),
            {ok, ~"hello\n"} = file:read_file(Out);
        #{wasi := false} ->
            {error, #{class := wasi, kind := unavailable}} =
                wasmtime:instantiate(Mod, #{wasi => #{stdout => {file, Out}}}),
            %% without the option the WASI imports are simply missing
            {error, #{class := link}} = wasmtime:instantiate(Mod)
    end,
    ok.

deserialize_and_call(Config) ->
    Mod = load(Config, "basic"),
    [{~"memory", memory}, {~"add", func} | _] = wasmtime:exports(Mod),
    {ok, Inst} = wasmtime:instantiate(Mod),
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2]),
    {error, #{class := trap, kind := unreachable}} = wasmtime:call(Inst, ~"boom", []),
    ok.

deserialize_garbage(_) ->
    {error, #{class := compile}} = wasmtime:deserialize(<<"not precompiled">>),
    {error, #{class := compile}} = wasmtime:deserialize(<<0, "asm", 1, 0, 0, 0>>),
    ok.

host_functions(Config) ->
    Mod = load(Config, "imports"),
    {ok, Inst} = wasmtime:instantiate(Mod, #{
        imports => #{{~"env", ~"twice"} => fun(_, [X]) -> {ok, [X * 2]} end}
    }),
    {ok, [42]} = wasmtime:call(Inst, ~"run", [21]),
    {error, #{class := link}} = wasmtime:instantiate(Mod),
    ok.

memory_access(Config) ->
    {ok, Inst} = wasmtime:instantiate(load(Config, "basic")),
    {ok, ~"hello"} = wasmtime:read_memory(Inst, 0, 5),
    ok = wasmtime:write_memory(Inst, 0, ~"J"),
    {ok, [$J]} = wasmtime:call(Inst, ~"load", [0]),
    {ok, {1, 65536}} = wasmtime:memory_size(Inst),
    ok.

interrupt(Config) ->
    {ok, Inst} = wasmtime:instantiate(load(Config, "basic")),
    {error, #{class := trap, kind := timeout}} = wasmtime:call(Inst, ~"loop", [], #{timeout => 100}),
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2]),
    ok.

streams(Config) ->
    %% the erlang imports need no compiler
    {ok, Inst} = wasmtime:instantiate(load(Config, "channel")),
    ok = wasmtime:send(Inst, ~"hi"),
    ok = wasmtime:close(Inst),
    {ok, [1]} = wasmtime:call(Inst, ~"echo", []),
    Ref = wasmtime:ref(Inst),
    receive
        {wasmtime_stream, Ref, channel, ~"hi"} -> ok
    after 2000 -> error(no_message)
    end,
    %% stdin => stream forwards through a module compiled on first use
    case wasmtime:features() of
        #{wasi := true} ->
            {error, #{kind := unavailable}} =
                wasmtime:instantiate(load(Config, "wasi"), #{wasi => #{stdin => stream}});
        _ ->
            ok
    end.
