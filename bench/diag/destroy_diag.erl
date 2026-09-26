%% Temporary: where instantiate, handle and destroy spend their time on
%% Linux. Removed before merge.
-module(destroy_diag).
-export([main/1]).

main([Reactor, Work, Mode]) ->
    ok = filelib:ensure_path(Work ++ "/init"),
    ok = filelib:ensure_path(Work ++ "/tmp"),
    ok = file:write_file(Work ++ "/init/main.py",
        "import _hornbeam, json\ndef main(c):\n"
        "    return _hornbeam.call('e', json.dumps({'s': sum(range(100))})).decode()\n"),
    ok = file:write_file(Work ++ "/init/context.json", "null"),
    Imports = #{
        {~"worker", ~"result"} => fun(_, _) -> {ok, []} end,
        {~"hornbeam", ~"call"} => fun(_, _) -> {ok, [2]} end,
        {~"hornbeam", ~"take"} => fun(I, [P, L]) ->
            ok = wasmtime:write_memory(I, P, binary:part(~"ok", 0, L)), {ok, [L]} end
    },
    Opts = #{imports => Imports, wasi => #{args => [~"python"],
        dirs => [{"/", Work ++ "/init", read}, {"/lib", Reactor ++ "/py_reactor_lib", read},
                 {"/tmp", Work ++ "/tmp", write}], clocks => monotonic}},
    {ok, Wasm} = file:read_file(Reactor ++ "/py_reactor.wasm"),
    {ok, Pre} = wasmtime:preinit(Wasm, Opts, [~"_initialize", ~"init", ~"handle"]),
    {ok, M0} = wasmtime:compile(Pre),
    {ok, C} = wasmtime:serialize(M0),
    Cw = Work ++ "/m.cwasm",
    ok = file:write_file(Cw, C),
    Configs = case Mode of
        "all" -> [{"on_demand", #{}},
                  {"pool keep=0", pool(0)},
                  {"pool keep=64M", pool(64 bsl 20)}];
        "pool" -> [{"pool keep=64M", pool(64 bsl 20)}]
    end,
    [begin
        {ok, M} = wasmtime:deserialize_file(Cw, Cfg),
        run(Name ++ " cpython", M, Opts),
        {ok, B} = wasmtime:compile({wat, "(module (memory (export \"memory\") 640) (data (i32.const 0) \"x\")"
            " (func (export \"handle\") (result i32) (i32.store (i32.const 1000000) (i32.const 1)) i32.const 0))"}, Cfg),
        run(Name ++ " bare 40MB", B, #{}),
        {ok, N} = wasmtime:compile({wat, "(module (func (export \"handle\") (result i32) i32.const 0))"}, Cfg),
        run(Name ++ " no memory", N, #{})
     end || {Name, Cfg} <- Configs],
    ok.

pool(Keep) ->
    #{allocator => pooling, pooling => #{instances => 64, max_memory => 256 bsl 20, keep_resident => Keep}}.

run(Name, M, Opts) ->
    [cycle(M, Opts) || _ <- lists:seq(1, 50)],
    Ts = [cycle(M, Opts) || _ <- lists:seq(1, 400)],
    P = fun(L) -> lists:nth(200, lists:sort(L)) end,
    io:format("~-26s instantiate ~5w  handle ~5w  destroy ~5w us (p50)~n",
        [Name, P([A || {A, _, _} <- Ts]), P([B || {_, B, _} <- Ts]), P([C || {_, _, C} <- Ts])]).

cycle(M, Opts) ->
    T0 = erlang:monotonic_time(microsecond),
    {ok, I} = wasmtime:instantiate(M, Opts),
    T1 = erlang:monotonic_time(microsecond),
    {ok, [0]} = wasmtime:call(I, ~"handle", []),
    T2 = erlang:monotonic_time(microsecond),
    ok = wasmtime:destroy(I),
    T3 = erlang:monotonic_time(microsecond),
    {T1 - T0, T2 - T1, T3 - T2}.
