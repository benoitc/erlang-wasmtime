%% The acceptance benchmark for pre-initialized CPython, with hornbeam's
%% reactor (bench/py_reactor, built by scripts/build-py-reactor.sh):
%%
%%   pre-initialize py_reactor.wasm with `_initialize`, `init` and one
%%   `handle`, then per request: instantiate, `handle` a staged `main.py`
%%   doing json work and a `hornbeam.call`, destroy.
%%
%% Run with scripts/bench-reactor.sh. Prints a Markdown report.
-module(reactor_bench).

-export([main/1]).

-define(KEEP_RESIDENT, 64 bsl 20).

main([Reactor, Work]) ->
    Wasm = filename:join(Reactor, "py_reactor.wasm"),
    Lib = filename:join(Reactor, "py_reactor_lib"),
    ok = filelib:ensure_path(Work),
    Env = #{lib => Lib, work => Work},
    io:format("# Pre-initialized CPython on erlang_wasmtime~n~n"),
    io:format("~s, ~p schedulers, Wasmtime ~s~n~n", [
        system(), erlang:system_info(schedulers_online), wasmtime:version()
    ]),
    Mod = prepare(Wasm, Env),
    single(Mod, Env),
    keep_resident(Env),
    concurrent(Mod, Env),
    host_calls(Mod, Env),
    memory(Mod, Env),
    isolation(Mod, Env),
    deadline(Mod, Env),
    ok.

%% ------------------------------------------------------------------ setup

pool(Keep) ->
    #{
        allocator => pooling,
        pooling => #{instances => 256, max_memory => 256 bsl 20, keep_resident => Keep}
    }.

prepare(Wasm, Env) ->
    {ok, Bin} = file:read_file(Wasm),
    Init = stage(Env, "init", "def main(context):\n    return None\n", "null"),
    {PreUs, {ok, Pre}} = timer:tc(fun() ->
        wasmtime:preinit(Bin, opts(Env, Init), [~"_initialize", ~"init", ~"handle"])
    end),
    {CompileUs, {ok, Mod0}} = timer:tc(fun() -> wasmtime:compile(Pre, pool(?KEEP_RESIDENT)) end),
    {ok, Cwasm} = wasmtime:serialize(Mod0),
    Path = filename:join(maps:get(work, Env), "py_reactor.cwasm"),
    ok = file:write_file(Path, Cwasm),
    {LoadUs, {ok, Mod}} = timer:tc(fun() ->
        wasmtime:deserialize_file(Path, pool(?KEEP_RESIDENT))
    end),
    row_header(["Step", "Time", "Size"]),
    row(["pre-initialize (`_initialize`, `init`, `handle`)", ms(PreUs), mb(byte_size(Pre))]),
    row(["compile", ms(CompileUs), mb(byte_size(Cwasm))]),
    row(["`deserialize_file/2`", ms(LoadUs), "-"]),
    io:format("~n"),
    Mod.

stage(#{work := Work}, Name, Main, Context) ->
    Dir = filename:join(Work, Name),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "main.py"), Main),
    ok = file:write_file(filename:join(Dir, "context.json"), Context),
    Dir.

%% The same preopens, in the same order, at capture and at every request:
%% the guest's C library reads the preopen table during `_initialize`, so the
%% table is part of the image. `/tmp` is writable; requests share one
%% directory unless given their own.
opts(Env, Root) -> opts(Env, Root, tmp(Env, "tmp")).
opts(#{lib := Lib}, Root, Tmp) ->
    #{
        imports => imports(),
        wasi => #{
            args => [~"python"],
            dirs => [{"/", Root, read}, {"/lib", Lib, read}, {"/tmp", Tmp, write}],
            clocks => monotonic
        }
    }.

tmp(#{work := Work}, Name) ->
    Dir = filename:join(Work, Name),
    ok = filelib:ensure_path(Dir),
    _ = file:delete(filename:join(Dir, "marker")),
    Dir.

%% worker.result, hornbeam.call, hornbeam.take, as hornbeam binds them: the
%% capability's result waits in the process dictionary between call and take.
imports() ->
    #{
        {~"worker", ~"result"} => fun(I, [P, L]) ->
            {ok, B} = wasmtime:read_memory(I, P, L),
            put(result, B),
            {ok, []}
        end,
        {~"hornbeam", ~"call"} => fun(I, [NP, NL, IP, IL]) ->
            {ok, Name} = wasmtime:read_memory(I, NP, NL),
            {ok, In} = wasmtime:read_memory(I, IP, IL),
            Out = <<Name/binary, ":", In/binary>>,
            put(capability, Out),
            {ok, [byte_size(Out)]}
        end,
        {~"hornbeam", ~"take"} => fun(I, [P, L]) ->
            ok = wasmtime:write_memory(I, P, binary:part(get(capability), 0, L)),
            {ok, [L]}
        end
    }.

request(Mod, Opts) ->
    request(Mod, Opts, #{}).
request(Mod, Opts, CallOpts) ->
    erase(result),
    T0 = now_us(),
    {ok, I} = wasmtime:instantiate(Mod, Opts),
    T1 = now_us(),
    R = wasmtime:call(I, ~"handle", [], CallOpts),
    T2 = now_us(),
    ok = wasmtime:destroy(I),
    T3 = now_us(),
    {R, get(result), {T1 - T0, T2 - T1, T3 - T2, T3 - T0}}.

json_main() ->
    "import _hornbeam, json\n"
    "def main(context):\n"
    "    doc = json.loads(json.dumps({'items': list(range(context['n']))}))\n"
    "    cap = _hornbeam.call('echo', json.dumps({'sum': sum(doc['items'])}))\n"
    "    return {'sum': sum(doc['items']), 'cap': cap.decode()}\n".

%% ------------------------------------------------------------------ cases

single(Mod, Env) ->
    Opts = opts(Env, stage(Env, "req", json_main(), "{\"n\": 100}")),
    {{ok, [0]}, Result, _} = request(Mod, Opts),
    <<"{\"ok\": {\"sum\": 4950, \"cap\": \"echo:{\\\"sum\\\": 4950}\"}}">> = Result,
    [request(Mod, Opts) || _ <- lists:seq(1, 100)],
    Ts = [T || {{ok, [0]}, _, T} <- [request(Mod, Opts) || _ <- lists:seq(1, 1000)]],
    io:format(
        "## One caller~n~n1000 requests: instantiate, `handle` (json and one `hornbeam.call`), destroy.~n~n"
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

%% The same requests on an engine that releases every page of a freed slot.
keep_resident(#{work := Work} = Env) ->
    {ok, Mod} = wasmtime:deserialize_file(filename:join(Work, "py_reactor.cwasm"), pool(0)),
    Opts = opts(Env, stage(Env, "req", json_main(), "{\"n\": 100}")),
    [request(Mod, Opts) || _ <- lists:seq(1, 100)],
    Ts = [T || {{ok, [0]}, _, {_, _, _, T}} <- [request(Mod, Opts) || _ <- lists:seq(1, 1000)]],
    io:format(
        "With `keep_resident => 0` instead of 64 MB: total p50 ~s, p99 ~s.~n~n",
        [us(percentile(Ts, 50)), us(percentile(Ts, 99))]
    ).

concurrent(Mod, Env) ->
    Opts = opts(Env, stage(Env, "req", json_main(), "{\"n\": 100}")),
    io:format("## Concurrent callers~n~nEach caller runs requests back to back for 5 s.~n~n"),
    row_header(["Callers", "Requests/s", "p50", "p99"]),
    [
        begin
            {Rate, Ls} = load(N, 5000, fun() -> request(Mod, Opts) end),
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

%% N processes calling Fun until Ms have passed: {Requests per second, latencies}.
load(N, Ms, Fun) ->
    Self = self(),
    Deadline = now_us() + Ms * 1000,
    Loop = fun Loop(Acc) ->
        case now_us() < Deadline of
            true ->
                {{ok, [0]}, _, {_, _, _, T}} = Fun(),
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

%% The round trip of one hornbeam.call: a request making 100 of them against
%% one making none, both under 14 concurrent callers.
host_calls(Mod, Env) ->
    Main = fun(Calls) ->
        "import _hornbeam\n"
        "def main(context):\n"
        "    for i in range(" ++ integer_to_list(Calls) ++
            "):\n"
            "        _hornbeam.call('echo', 'x')\n"
            "    return None\n"
    end,
    Handle = fun(Name, Calls) ->
        Opts = opts(Env, stage(Env, Name, Main(Calls), "null")),
        {_, Ls} = load(14, 3000, fun() -> request(Mod, Opts) end),
        percentile(Ls, 50)
    end,
    None = Handle("calls0", 0),
    Hundred = Handle("calls100", 100),
    io:format("## Host calls~n~n"),
    io:format(
        "One `hornbeam.call` (a `call` and a `take` through the calling process), 14 callers: "
        "**~.1f us** round trip (p50 of a request with 100 calls ~s, with none ~s).~n~n",
        [(Hundred - None) / 100, us(Hundred), us(None)]
    ).

%% Resident memory of K live instances, each having served one request.
memory(Mod, Env) ->
    Opts = opts(Env, stage(Env, "req", json_main(), "{\"n\": 100}")),
    erlang:garbage_collect(),
    Before = rss(),
    K = 50,
    Insts = [
        begin
            {ok, I} = wasmtime:instantiate(Mod, Opts),
            {ok, [0]} = wasmtime:call(I, ~"handle", []),
            I
        end
     || _ <- lists:seq(1, K)
    ],
    After = rss(),
    [ok = wasmtime:destroy(I) || I <- Insts],
    io:format("## Memory~n~n"),
    io:format(
        "~p live instances after one request each: **~.1f MB** resident per instance "
        "(the 40 MB image is shared; this is the pages each one wrote, plus its thread).~n~n",
        [K, (After - Before) / K / 1024]
    ).

isolation(Mod, Env) ->
    %% a global mutated in one request is fresh in the next
    Counter = opts(
        Env,
        stage(
            Env,
            "counter",
            "import builtins\n"
            "def main(context):\n"
            "    n = getattr(builtins, '_hb_counter', 0)\n"
            "    builtins._hb_counter = n + 1\n"
            "    return n\n",
            "null"
        )
    ),
    Seen = [R || {{ok, [0]}, R, _} <- [request(Mod, Counter) || _ <- lists:seq(1, 5)]],
    Fresh = lists:all(fun(R) -> R =:= <<"{\"ok\": 0}">> end, Seen),
    %% a file written under one instance's writable preopen is not seen by another
    Write = stage(
        Env,
        "write",
        "import os\n"
        "def main(context):\n"
        "    seen = os.path.exists('/tmp/marker')\n"
        "    open('/tmp/marker', 'w').write('x')\n"
        "    return seen\n",
        "null"
    ),
    [{{ok, [0]}, A, _}, {{ok, [0]}, B, _}] = [
        request(Mod, opts(Env, Write, tmp(Env, N)))
     || N <- ["tmp_a", "tmp_b"]
    ],
    Separate = A =:= <<"{\"ok\": false}">> andalso B =:= <<"{\"ok\": false}">>,
    io:format("## Isolation~n~n"),
    io:format("- A global set in one request is unset in the next: **~s** (~s).~n", [
        yes(Fresh), lists:join(", ", Seen)
    ]),
    io:format(
        "- A file written under one instance's writable preopen is not seen by another: **~s**.~n~n",
        [
            yes(Separate)
        ]
    ).

deadline(Mod, Env) ->
    Loop = opts(
        Env, stage(Env, "loop", "def main(context):\n    while True:\n        pass\n", "null")
    ),
    Ok = opts(Env, stage(Env, "req", json_main(), "{\"n\": 100}")),
    Timeout = 50,
    Overs = [
        begin
            {{error, #{kind := timeout}}, _, {_, T, _, _}} = request(Mod, Loop, #{
                timeout => Timeout
            }),
            T / 1000 - Timeout
        end
     || _ <- lists:seq(1, 20)
    ],
    {{ok, [0]}, _, _} = request(Mod, Ok),
    io:format("## Deadline~n~n"),
    io:format(
        "`handle` running `while True: pass` with `timeout => ~p`: returns ~.2f ms after the deadline "
        "at worst (median ~.2f ms, 20 runs); the next request is served normally.~n",
        [Timeout, lists:max(Overs), percentile(Overs, 50)]
    ).

%% ---------------------------------------------------------------- helpers

percentile(L, P) ->
    S = lists:sort(L),
    lists:nth(max(1, (length(S) * P + 99) div 100), S).

now_us() -> erlang:monotonic_time(microsecond).
ms(Us) -> io_lib:format("~.1f ms", [Us / 1000]).
us(Us) when is_float(Us) -> io_lib:format("~.2f ms", [Us / 1000]);
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
