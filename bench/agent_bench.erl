%% The component benchmark: a componentize-py agent (bench/agent, built by
%% scripts/build-agent.sh), per request instantiated from a pool, `handle`
%% called once with json work and one `call` on a capability import, and
%% destroyed. The component counterpart of reactor_bench.erl.
%%
%% Run with scripts/bench-agent.sh. Prints a Markdown report.
-module(agent_bench).

-export([main/1]).

%% A componentize-py agent holds 16 core instances, 1 memory and 2 tables.
-define(POOL, #{
    allocator => pooling,
    pooling => #{
        instances => 256,
        core_instances => 256 * 16,
        memories => 256,
        tables => 256 * 2,
        max_memory => 256 bsl 20,
        keep_resident => 64 bsl 20
    }
}).

main([Wasm, Work]) ->
    ok = filelib:ensure_path(Work),
    io:format("# A componentize-py agent on erlang_wasmtime~n~n"),
    io:format("~s, ~p schedulers, Wasmtime ~s~n~n", [
        system(), erlang:system_info(schedulers_online), wasmtime:version()
    ]),
    Mod = prepare(Wasm, Work),
    single(Mod),
    concurrent(Mod),
    host_calls(Mod),
    memory(Mod),
    isolation(Mod),
    deadline(Mod),
    ok.

prepare(Wasm, Work) ->
    {ok, Bin} = file:read_file(Wasm),
    {CompileUs, {ok, Mod0}} = timer:tc(fun() -> wasmtime:compile(Bin, ?POOL) end),
    {ok, Cwasm} = wasmtime:serialize(Mod0),
    Path = filename:join(Work, "agent.cwasm"),
    ok = file:write_file(Path, Cwasm),
    {LoadUs, {ok, Mod}} = timer:tc(fun() -> wasmtime:deserialize_file(Path, ?POOL) end),
    row_header(["Step", "Time", "Size"]),
    row(["compile", ms(CompileUs), mb(byte_size(Cwasm))]),
    row(["`deserialize_file/2`", ms(LoadUs), "-"]),
    io:format("~n"),
    Mod.

opts() ->
    #{
        imports => #{
            {~"hornbeam:agent/caps", ~"call"} => fun([Name, Payload]) ->
                {ok, <<Name/binary, ":", Payload/binary>>}
            end
        },
        wasi => #{clocks => monotonic}
    }.

request(Mod, Context) -> request(Mod, Context, #{}).
request(Mod, Context, CallOpts) ->
    T0 = now_us(),
    {ok, I} = wasmtime:instantiate(Mod, opts()),
    T1 = now_us(),
    R = wasmtime:call(I, ~"handle", [Context], CallOpts),
    T2 = now_us(),
    ok = wasmtime:destroy(I),
    T3 = now_us(),
    {R, {T1 - T0, T2 - T1, T3 - T2, T3 - T0}}.

-define(JSON, ~"{\"n\": 100}").

single(Mod) ->
    {{ok, Result}, _} = request(Mod, ?JSON),
    <<"{\"ok\": {\"sum\": 4950, \"cap\": \"echo:{\\\"sum\\\": 4950}\"}}">> = Result,
    [request(Mod, ?JSON) || _ <- lists:seq(1, 100)],
    Ts = [T || {{ok, _}, T} <- [request(Mod, ?JSON) || _ <- lists:seq(1, 1000)]],
    io:format(
        "## One caller~n~n1000 requests: instantiate, `handle` (json and one capability call), destroy.~n~n"
    ),
    row_header(["Phase", "p50", "p90", "p99"]),
    [
        row([Name | [us(percentile(L, P)) || P <- [50, 90, 99]]])
     || {Name, L} <- [
            {"instantiate", [A || {A, _, _, _} <- Ts]},
            {"`handle`", [B || {_, B, _, _} <- Ts]},
            {"destroy", [C || {_, _, C, _} <- Ts]},
            {"**total**", [D || {_, _, _, D} <- Ts]}
        ]
    ],
    io:format("~n").

concurrent(Mod) ->
    io:format("## Concurrent callers~n~nEach caller runs requests back to back for 5 s.~n~n"),
    row_header(["Callers", "Requests/s", "p50", "p99"]),
    [
        begin
            {Rate, Ls} = load(N, 5000, fun() -> request(Mod, ?JSON) end),
            row([
                integer_to_list(N),
                integer_to_list(Rate),
                us(percentile(Ls, 50)),
                us(percentile(Ls, 99))
            ])
        end
     || N <- [1, 4, 8, 14, 28]
    ],
    io:format("~n").

load(N, Ms, Fun) ->
    Self = self(),
    Deadline = now_us() + Ms * 1000,
    Loop = fun Loop(Acc) ->
        case now_us() < Deadline of
            true ->
                {{ok, _}, {_, _, _, T}} = Fun(),
                Loop([T | Acc]);
            false ->
                Acc
        end
    end,
    T0 = now_us(),
    Pids = [spawn_link(fun() -> Self ! {done, self(), Loop([])} end) || _ <- lists:seq(1, N)],
    All = lists:append([
        receive
            {done, P, L} -> L
        end
     || P <- Pids
    ]),
    {round(length(All) * 1.0e6 / (now_us() - T0)), All}.

host_calls(Mod) ->
    Calls = fun(N) ->
        Ctx = iolist_to_binary(["{\"mode\": \"calls\", \"n\": ", integer_to_list(N), "}"]),
        {_, Ls} = load(14, 3000, fun() -> request(Mod, Ctx) end),
        percentile(Ls, 50)
    end,
    None = Calls(0),
    Hundred = Calls(100),
    io:format("## Host calls~n~n"),
    io:format(
        "One capability `call` (one typed import call), 14 callers: **~.1f us** round trip "
        "(p50 of a request with 100 calls ~s, with none ~s).~n~n",
        [(Hundred - None) / 100, us(Hundred), us(None)]
    ).

memory(Mod) ->
    erlang:garbage_collect(),
    Before = rss(),
    K = 50,
    Insts = [
        begin
            {ok, I} = wasmtime:instantiate(Mod, opts()),
            {ok, _} = wasmtime:call(I, ~"handle", [?JSON]),
            I
        end
     || _ <- lists:seq(1, K)
    ],
    After = rss(),
    [ok = wasmtime:destroy(I) || I <- Insts],
    io:format("## Memory~n~n"),
    io:format("~p live instances after one request each: **~.1f MB** resident per instance.~n~n", [
        K, (After - Before) / K / 1024
    ]).

isolation(Mod) ->
    Seen = [
        R
     || {{ok, R}, _} <- [request(Mod, ~"{\"mode\": \"counter\"}") || _ <- lists:seq(1, 5)]
    ],
    Fresh = lists:all(fun(R) -> R =:= <<"{\"ok\": 1}">> end, Seen),
    io:format("## Isolation~n~n"),
    io:format(
        "- A module global incremented in one request starts over in the next: **~s** (~s).~n~n", [
            yes(Fresh), lists:join(", ", Seen)
        ]
    ).

deadline(Mod) ->
    Timeout = 50,
    Overs = [
        begin
            {{error, #{kind := timeout}}, {_, T, _, _}} =
                request(Mod, ~"{\"mode\": \"loop\"}", #{timeout => Timeout}),
            T / 1000 - Timeout
        end
     || _ <- lists:seq(1, 20)
    ],
    {{ok, _}, _} = request(Mod, ?JSON),
    io:format("## Deadline~n~n"),
    io:format(
        "`handle` running `while True: pass` with `timeout => ~p`: returns ~.2f ms after the deadline "
        "at worst (median ~.2f ms, 20 runs); the next request is served normally.~n",
        [Timeout, lists:max(Overs), percentile(Overs, 50)]
    ).

percentile(L, P) ->
    S = lists:sort(L),
    lists:nth(max(1, (length(S) * P + 99) div 100), S).

now_us() -> erlang:monotonic_time(microsecond).
ms(Us) -> io_lib:format("~.1f ms", [Us / 1000]).
us(Us) -> io_lib:format("~.2f ms", [Us / 1000]).
mb(Bytes) -> io_lib:format("~.1f MB", [Bytes / 1048576]).
yes(true) -> "yes";
yes(false) -> "NO".

rss() ->
    list_to_integer(string:trim(os:cmd("ps -o rss= -p " ++ os:getpid()))).

system() ->
    case os:type() of
        {unix, darwin} ->
            string:trim(os:cmd("sysctl -n machdep.cpu.brand_string")) ++ ", macOS " ++
                string:trim(os:cmd("sw_vers -productVersion"));
        {unix, linux} ->
            string:trim(os:cmd("grep -m1 'model name' /proc/cpuinfo | cut -d: -f2")) ++ ", Linux " ++
                string:trim(os:cmd("uname -r"))
    end.

row_header(Cols) ->
    row(Cols),
    row(["---" || _ <- Cols]).
row(Cols) ->
    io:format("| ~s |~n", [lists:join(" | ", Cols)]).
