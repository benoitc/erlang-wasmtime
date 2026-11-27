%% Components: values, imports, resources, WASI 0.2. The fixtures and most
%% expectations are erlang_wasm's (see the _data README), so the two runtimes
%% answer the same terms for the same guests.
-module(wasmtime_component_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    detect_and_describe/1,
    from_text/1,
    precompiled/1,
    unsigned_integers/1,
    signed_integers/1,
    floats_bool_char/1,
    strings/1,
    lists/1,
    records_and_tuples/1,
    variants_enums_options_results/1,
    flags/1,
    bad_values_are_refused/1,
    host_imports_raw/1,
    host_imports_typed/1,
    host_resources/1,
    host_resource_drop_hook/1,
    host_resources_in_host_process/1,
    host_import_failures/1,
    missing_import/1,
    aggregate_import/1,
    resources/1,
    destroy_drops_resources/1,
    wasi_command/1,
    wasi_exit/1,
    wasi_stdin_stream/1,
    wasi_versioned_import/1,
    wasi_clocks_component/1,
    wasi_network_grant/1,
    wasi_network_timeout/1,
    wasi_http_grant/1,
    wasi_grants_refused/1,
    core_accessors_refused/1,
    pooled_components/1
]).

all() ->
    [{group, G} || {G, _, _} <- groups()].

groups() ->
    [
        {modules, [parallel], [detect_and_describe, from_text, precompiled, core_accessors_refused]},
        {values, [parallel], [
            unsigned_integers,
            signed_integers,
            floats_bool_char,
            strings,
            lists,
            records_and_tuples,
            variants_enums_options_results,
            flags,
            bad_values_are_refused
        ]},
        {imports, [parallel], [
            host_imports_raw,
            host_imports_typed,
            host_resources,
            host_resource_drop_hook,
            host_resources_in_host_process,
            host_import_failures,
            missing_import,
            aggregate_import
        ]},
        {resources, [parallel], [resources, destroy_drops_resources]},
        {wasi, [parallel], [
            wasi_command,
            wasi_exit,
            wasi_stdin_stream,
            wasi_versioned_import,
            wasi_clocks_component,
            wasi_network_grant,
            wasi_network_timeout,
            wasi_http_grant,
            wasi_grants_refused
        ]},
        {pool, [], [pooled_components]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wasi], Config).

end_per_suite(_) -> ok.

component(Config, Name) ->
    {ok, Bin} = file:read_file(filename:join(?config(data_dir, Config), Name ++ ".component.wasm")),
    {ok, Mod} = wasmtime:compile(Bin),
    Mod.

instance(Config, Name) -> instance(Config, Name, #{}).
instance(Config, Name, Opts) ->
    {ok, Inst} = wasmtime:instantiate(component(Config, Name), Opts),
    Inst.

%% ------------------------------------------------------------- modules

detect_and_describe(Config) ->
    Mod = component(Config, "hostcall"),
    component = wasmtime:module_kind(Mod),
    [{~"example:host/clock", instance}, {~"example:host/clock#now", func} | _] =
        wasmtime:imports(Mod),
    #{~"read-now" := {func, undefined}} = wasmtime:exports(Mod),
    module = wasmtime:module_kind(wasmtime_test:compile(~"(module)")),
    {ok, Bytes} = file:read_file(
        filename:join(?config(data_dir, Config), "vectors.component.wasm")
    ),
    {ok, Bytes} = wasmtime:validate(Bytes),
    ok.

from_text(_) ->
    {ok, Mod} = wasmtime:compile(
        {wat,
            ~"""
            (component
              (core module $m
                (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
              (core instance $i (instantiate $m))
              (func $add (param "a" u32) (param "b" u32) (result u32) (canon lift (core func $i "add")))
              (export "add" (func $add)))
            """}
    ),
    {ok, Inst} = wasmtime:instantiate(Mod),
    {ok, 42} = wasmtime:call(Inst, ~"add", [2, 40]),
    {error, #{kind := argument_arity}} = wasmtime:call(Inst, ~"add", [1]),
    {error, #{kind := unknown_export}} = wasmtime:call(Inst, ~"nope", []),
    ok.

precompiled(Config) ->
    {ok, Bin} = wasmtime:serialize(component(Config, "vectors")),
    {ok, Mod} = wasmtime:deserialize(Bin),
    component = wasmtime:module_kind(Mod),
    Path = filename:join(?config(priv_dir, Config), "vectors.cwasm"),
    ok = file:write_file(Path, Bin),
    {ok, FromFile} = wasmtime:deserialize_file(Path),
    {ok, Inst} = wasmtime:instantiate(FromFile),
    {ok, 7} = wasmtime:call(Inst, ~"echo-u8", [7]),
    ok.

core_accessors_refused(Config) ->
    Inst = instance(Config, "vectors"),
    {error, #{kind := component}} = wasmtime:get_global(Inst, ~"g"),
    {error, #{kind := component}} = wasmtime:table_size(Inst, ~"t"),
    {error, #{kind := no_memory}} = wasmtime:read_memory(Inst, 0, 1),
    ok.

%% ------------------------------------------------------------- values

rt(Config, Export, Values) ->
    Inst = instance(Config, "vectors"),
    [?assertEqual({ok, V}, wasmtime:call(Inst, Export, [V])) || V <- Values],
    ok.

unsigned_integers(Config) ->
    rt(Config, ~"echo-u8", [0, 1, 255]),
    rt(Config, ~"echo-u16", [0, 60000, 65535]),
    rt(Config, ~"echo-u32", [0, 4000000000, 4294967295]),
    rt(Config, ~"echo-u64", [0, 18446744073709551615]).

signed_integers(Config) ->
    rt(Config, ~"echo-s8", [-128, -1, 0, 127]),
    rt(Config, ~"echo-s16", [-32768, -1, 32767]),
    rt(Config, ~"echo-s32", [-2147483648, -1, 2147483647]),
    rt(Config, ~"echo-s64", [-9223372036854775808, -1, 9223372036854775807]).

floats_bool_char(Config) ->
    rt(Config, ~"echo-f32", [0.0, 1.5, -2.25]),
    rt(Config, ~"echo-f64", [0.0, 3.141592653589793, -1.0e300]),
    rt(Config, ~"echo-f64", [nan, infinity, neg_infinity]),
    rt(Config, ~"echo-bool", [true, false]),
    rt(Config, ~"echo-char", [$A, 16#20AC, 16#1F600]).

strings(Config) ->
    rt(Config, ~"echo-string", [
        <<>>, ~"ascii", <<"h", 16#C3, 16#A9, "llo, w", 16#C3, 16#B6, "rld">>
    ]).

lists(Config) ->
    rt(Config, ~"echo-list-u32", [[], [0], [1, 2, 4294967295]]),
    rt(Config, ~"echo-list-string", [[], [~"a", ~"", ~"ccc"]]).

records_and_tuples(Config) ->
    rt(Config, ~"echo-point", [#{~"x" => -1, ~"y" => 2}, #{~"x" => 0, ~"y" => 0}]),
    rt(Config, ~"echo-tuple", [{0, <<>>, false}, {200, ~"hi", true}]).

variants_enums_options_results(Config) ->
    rt(Config, ~"echo-shape", [
        {~"circle", 2.5}, {~"rect", #{~"x" => 1, ~"y" => -2}}, {~"unit", undefined}
    ]),
    rt(Config, ~"echo-color", [~"red", ~"green", ~"blue"]),
    rt(Config, ~"echo-option", [none, {some, 0}, {some, 42}]),
    rt(Config, ~"echo-result", [{ok, 0}, {ok, 7}, {error, <<>>}, {error, ~"bad"}]),
    %% a case without payload may be given bare
    Inst = instance(Config, "vectors"),
    {ok, {~"unit", undefined}} = wasmtime:call(Inst, ~"echo-shape", [~"unit"]),
    ok.

flags(Config) ->
    rt(Config, ~"echo-perms", [[], [~"read"], [~"read", ~"exec"], [~"read", ~"write", ~"exec"]]),
    %% declaration order, whatever the order given
    Inst = instance(Config, "vectors"),
    {ok, [~"read", ~"exec"]} = wasmtime:call(Inst, ~"echo-perms", [[~"exec", ~"read"]]),
    ok.

%% What the C API would abort the VM on is refused before it is reached.
bad_values_are_refused(Config) ->
    Inst = instance(Config, "vectors"),
    Bad = fun(Export, V) ->
        {error, #{class := link, kind := argument_type}} = wasmtime:call(Inst, Export, [V])
    end,
    Bad(~"echo-string", <<255, 254>>),
    Bad(~"echo-string", <<"a", 16#ED, 16#A0, 16#80>>),
    Bad(~"echo-char", 16#D800),
    Bad(~"echo-char", 16#110000),
    Bad(~"echo-u8", 256),
    Bad(~"echo-s8", -129),
    Bad(~"echo-u64", -1),
    Bad(~"echo-bool", 1),
    Bad(~"echo-color", ~"pink"),
    Bad(~"echo-perms", [~"fly"]),
    Bad(~"echo-point", #{~"x" => 1}),
    Bad(~"echo-shape", {~"hexagon", 1}),
    Bad(~"echo-tuple", {1, ~"a"}),
    Bad(~"echo-option", 42),
    Bad(~"echo-result", {'maybe', 1}),
    {ok, 1} = wasmtime:call(Inst, ~"echo-u8", [1]),
    ok.

%% ------------------------------------------------------------- imports

clock_imports(Now) ->
    #{
        {~"example:host/clock", ~"now"} => fun(_Inst, []) -> {ok, [Now]} end,
        {~"example:host/clock", ~"add"} => fun(_Inst, [A, B]) -> {ok, [A + B]} end
    }.

host_imports_raw(Config) ->
    Inst = instance(Config, "hostcall", #{imports => clock_imports(424242)}),
    {ok, 424242} = wasmtime:call(Inst, ~"read-now", {[], u64}, []),
    [
        {ok, S} = wasmtime:call(Inst, ~"read-add", [A, B])
     || {A, B, S} <- [{0, 0, 0}, {1, 2, 3}, {4294967294, 1, 4294967295}]
    ],
    ok.

host_imports_typed(Config) ->
    Imports = #{
        {~"example:host/clock", ~"now"} => wasmtime:import_fun({[], u64}, fun([]) -> 777 end),
        {~"example:host/clock", ~"add"} => wasmtime:import_fun({[u32, u32], u32}, fun([A, B]) ->
            A + B
        end)
    },
    Inst = instance(Config, "hostcall", #{imports => Imports}),
    {ok, 777} = wasmtime:call(Inst, ~"read-now", []),
    {ok, 30} = wasmtime:call(Inst, ~"read-add", [10, 20]),
    ok.

host_import_failures(Config) ->
    Base = clock_imports(1),
    Raise = instance(Config, "hostcall", #{
        imports => Base#{{~"example:host/clock", ~"now"} => fun([]) -> error(boom) end}
    }),
    {error, #{class := trap}} = wasmtime:call(Raise, ~"read-now", []),
    Wrong = instance(Config, "hostcall", #{
        imports => Base#{{~"example:host/clock", ~"now"} => fun([]) -> ~"not a u64" end}
    }),
    {error, #{class := trap}} = wasmtime:call(Wrong, ~"read-now", []),
    Refuse = instance(Config, "hostcall", #{
        imports => Base#{{~"example:host/clock", ~"now"} => fun(_, []) -> {error, denied} end}
    }),
    {error, #{class := trap, kind := host_error, ctx := #{reason := denied}}} =
        wasmtime:call(Refuse, ~"read-now", []),
    %% a component instance that trapped may not be entered again (a
    %% Component Model rule): a new instance is needed
    {error, #{class := trap, kind := cannot_enter_component}} =
        wasmtime:call(Refuse, ~"read-add", [1, 2]),
    ok.

missing_import(Config) ->
    {error, #{class := link}} = wasmtime:instantiate(component(Config, "hostcall")),
    ok.

aggregate_import(Config) ->
    Inst = instance(Config, "hostagg", #{
        imports => #{{~"example:agg/host", ~"shout"} => fun([S]) -> string:uppercase(S) end}
    }),
    [
        ?assertEqual(
            {ok, <<"<<", (string:uppercase(S))/binary, ">>">>},
            wasmtime:call(Inst, ~"announce", [S])
        )
     || S <- [<<>>, ~"hi there", <<"h", 16#C3, 16#A9, "llo">>]
    ],
    ok.

%% ----------------------------------------------------------- resources

q(Name) -> <<"example:counter/counters#", Name/binary>>.

resources(Config) ->
    Inst = instance(Config, "counter"),
    {ok, A} = wasmtime:call(Inst, q(~"make-counter"), [0]),
    {ok, B} = wasmtime:call(Inst, q(~"make-counter"), [100]),
    true = is_integer(A) andalso A =/= B,
    {ok, 1} = wasmtime:call(Inst, q(~"[method]counter.increment"), [A, 1]),
    {ok, 105} = wasmtime:call(Inst, q(~"[method]counter.increment"), [B, 5]),
    {ok, 1} = wasmtime:call(Inst, q(~"[method]counter.get"), [A]),
    {ok, 105} = wasmtime:call(Inst, q(~"[method]counter.get"), [B]),
    ok = wasmtime:drop_resource(Inst, q(~"[dtor]counter"), A),
    {error, #{kind := badarg}} = wasmtime:drop_resource(Inst, A),
    {error, #{kind := argument_type}} = wasmtime:call(Inst, q(~"[method]counter.get"), [A]),
    {error, #{kind := argument_type}} = wasmtime:call(Inst, q(~"[method]counter.get"), [9999]),
    {ok, 105} = wasmtime:call(Inst, q(~"[method]counter.get"), [B]),
    ok = wasmtime:drop_resource(Inst, B),
    ok.

destroy_drops_resources(Config) ->
    Inst = instance(Config, "counter"),
    [{ok, _} = wasmtime:call(Inst, q(~"make-counter"), [N]) || N <- lists:seq(1, 100)],
    ok = wasmtime:destroy(Inst),
    {error, #{kind := stopped}} = wasmtime:call(Inst, q(~"[method]counter.get"), [1]),
    ok.

%% ---------------------------------------------------------------- WASI

wasi_command(Config) ->
    Argv = instance(Config, "argv", #{wasi => #{args => ["prog", "a", "b"], stdout => capture}}),
    ok = wasmtime:run(Argv),
    {ok, {~"a\nb\n", <<>>, {0, 0}}} = wasmtime:read_output(Argv),
    Env = instance(Config, "envvar", #{wasi => #{env => [{"GREETING", "hi"}], stdout => capture}}),
    ok = wasmtime:run(Env),
    {ok, {~"hi\n", <<>>, {0, 0}}} = wasmtime:read_output(Env),
    Upper = instance(Config, "realupper", #{
        wasi => #{stdin => {binary, ~"make me loud"}, stdout => capture}
    }),
    ok = wasmtime:run(Upper),
    {ok, {~"MAKE ME LOUD", <<>>, {0, 0}}} = wasmtime:read_output(Upper),
    %% without wasi the WASI imports are unmet
    {error, #{class := link}} = wasmtime:instantiate(component(Config, "argv")),
    ok.

%% WASI 0.2's exit carries success or failure only: a non-zero status is 1.
wasi_exit(Config) ->
    ok = wasmtime:run(instance(Config, "exitcode", #{wasi => #{}})),
    {error, #{class := trap, ctx := #{wasi_exit := 1}}} =
        wasmtime:run(instance(Config, "exitcode", #{wasi => #{args => ["x", "7"]}})),
    ok.

wasi_stdin_stream(Config) ->
    Inst = instance(Config, "realupper", #{
        wasi => #{stdin => stream, stdout => stream}, stream => self()
    }),
    {ok, R} = wasmtime:call_async(Inst, ~"wasi:cli/run#run", []),
    ok = wasmtime:send(Inst, ~"first "),
    timer:sleep(50),
    ok = wasmtime:send(Inst, ~"second"),
    ok = wasmtime:close(Inst),
    {ok, {ok, undefined}} = wasmtime:await(Inst, R, 5000),
    ~"FIRST SECOND" = collect(Inst, <<>>),
    ok.

collect(Inst, Acc) ->
    Ref = wasmtime:ref(Inst),
    receive
        {wasmtime_stream, Ref, stdout, B} -> collect(Inst, <<Acc/binary, B/binary>>)
    after 200 -> Acc
    end.

wasi_versioned_import(Config) ->
    Inst = instance(Config, "wasiver", #{wasi => #{}}),
    {ok, N} = wasmtime:call(Inst, ~"roll", []),
    true = is_integer(N),
    ok.

wasi_clocks_component(Config) ->
    Run = fun(Arg, Clocks) ->
        Inst = instance(Config, "clocks", #{
            wasi => #{args => ["clocks", Arg], stdout => capture, clocks => Clocks}
        }),
        {wasmtime:run(Inst), wasmtime:read_output(Inst)}
    end,
    {ok, {ok, {<<"wall ", _/binary>>, _, _}}} = Run("wall", all),
    {ok, {ok, {~"mono true\n", _, _}}} = Run("mono", all),
    {ok, {ok, {~"mono true\n", _, _}}} = Run("mono", monotonic),
    {{error, #{class := trap, kind := clock_refused}}, _} = Run("wall", monotonic),
    ok.

%% ---------------------------------------------------------------- pool

pooled_components(Config) ->
    {ok, Bin} = file:read_file(filename:join(?config(data_dir, Config), "vectors.component.wasm")),
    {ok, Mod} = wasmtime:compile(Bin, wasmtime_test:pooling()),
    [
        begin
            {ok, I} = wasmtime:instantiate(Mod),
            {ok, 5} = wasmtime:call(I, ~"echo-u32", [5]),
            ok = wasmtime:destroy(I)
        end
     || _ <- lists:seq(1, 200)
    ],
    ok.

%% ------------------------------------------------------- network and http

%% A listener on the loopback that answers each connection with `Reply`.
serve(Reply) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    Pid = spawn(fun() -> accept_loop(L, Reply) end),
    ok = gen_tcp:controlling_process(L, Pid),
    {Pid, integer_to_list(Port)}.

accept_loop(L, Reply) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            _ = gen_tcp:recv(S, 0, 2000),
            _ = gen_tcp:send(S, Reply),
            _ = gen_tcp:close(S),
            accept_loop(L, Reply);
        {error, _} ->
            ok
    end.

net(Config, Args, Grants) -> command(Config, "net", Args, Grants).

command(Config, Name, Args, Grants) ->
    Inst = instance(Config, Name, #{wasi => Grants#{args => [Name | Args], stdout => capture}}),
    Result = wasmtime:run(Inst),
    {ok, {Out, _, _}} = wasmtime:read_output(Inst),
    {Result, Out}.

%% Sockets are denied unless `network => all`, which needs a library built
%% with this project's patches (`features/0`, `wasi_sockets`).
wasi_network_grant(Config) ->
    {Server, Port} = serve(~"pong\n"),
    Addr = "127.0.0.1:" ++ Port,
    {{error, #{class := trap, ctx := #{wasi_exit := 1}}}, <<"refused: ", _/binary>>} = net(
        Config, ["tcp", Addr], #{}
    ),
    {{error, #{class := trap, ctx := #{wasi_exit := _}}}, <<"refused: ", _/binary>>} =
        net(Config, ["tcp", Addr], #{network => none}),
    {{error, #{class := trap, ctx := #{wasi_exit := _}}}, <<"refused: ", _/binary>>} = net(
        Config, ["resolve", "localhost"], #{}
    ),
    case wasmtime:features() of
        #{wasi_sockets := true} ->
            {ok, ~"pong\n"} = net(Config, ["tcp", Addr], #{network => all}),
            {ok, ~"true\n"} = net(Config, ["resolve", "localhost"], #{network => all}),
            %% a connection nobody accepts is the guest's error, not ours
            {{error, #{class := trap, ctx := #{wasi_exit := 1}}}, <<"refused: ", _/binary>>} =
                net(Config, ["tcp", "127.0.0.1:" ++ closed_port()], #{network => all});
        #{wasi_sockets := false} ->
            {error, #{class := link, kind := unavailable}} = wasmtime:instantiate(
                component(Config, "net"), #{wasi => #{network => all}}
            )
    end,
    exit(Server, kill),
    ok.

closed_port() ->
    {ok, L} = gen_tcp:listen(0, [{ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    ok = gen_tcp:close(L),
    integer_to_list(Port).

%% A guest waiting on a peer that never answers: the call's deadline is
%% reported to the caller, and the guest ends when the peer closes.
wasi_network_timeout(Config) ->
    case wasmtime:features() of
        #{wasi_sockets := true} ->
            {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
            {ok, Port} = inet:port(L),
            Inst = instance(Config, "net", #{
                wasi => #{
                    network => all,
                    args => ["net", "tcp", "127.0.0.1:" ++ integer_to_list(Port)]
                }
            }),
            {error, #{kind := timeout}} = wasmtime:run(Inst, #{timeout => 200}),
            {ok, S} = gen_tcp:accept(L, 2000),
            ok = gen_tcp:close(S),
            ok = gen_tcp:close(L),
            ok;
        #{wasi_sockets := false} ->
            {skip, "no sockets in this library"}
    end.

%% `wasi:http` is not linked unless `http => all`, and does not need the
%% network grant: Wasmtime makes the request, not the guest's sockets.
wasi_http_grant(Config) ->
    case wasmtime:features() of
        #{wasi_http := true} ->
            {Server, Port} = serve(~"HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n"),
            Args = ["127.0.0.1:" ++ Port, "/"],
            {error, #{class := link}} = wasmtime:instantiate(component(Config, "httpget"), #{
                wasi => #{args => ["httpget" | Args]}
            }),
            {ok, ~"204\n"} = command(Config, "httpget", Args, #{http => all}),
            {ok, ~"idle\n"} = command(Config, "httpget", [], #{http => all}),
            exit(Server, kill),
            ok;
        _ ->
            {error, #{class := link, kind := unavailable}} = wasmtime:instantiate(
                component(Config, "httpget"), #{wasi => #{http => all}}
            ),
            ok
    end.

wasi_grants_refused(Config) ->
    %% a core module has no WASI 0.2 to grant http on
    {ok, Core} = wasmtime:compile({wat, ~"(module)"}),
    case wasmtime:features() of
        #{wasi_http := true} ->
            {error, #{class := link, kind := unsupported}} =
                wasmtime:instantiate(Core, #{wasi => #{http => all}});
        _ ->
            ok
    end,
    %% nor sockets: preview 1 has none
    NetworkKind =
        case wasmtime:features() of
            #{wasi_sockets := true} -> unsupported;
            #{wasi_sockets := false} -> unavailable
        end,
    {error, #{class := link, kind := NetworkKind}} =
        wasmtime:instantiate(Core, #{wasi => #{network => all}}),
    {ok, _} = wasmtime:instantiate(Core, #{wasi => #{network => none, http => none}}),
    %% no grant by address
    try
        wasmtime:instantiate(component(Config, "net"), #{wasi => #{network => [{~"127.0.0.1", 80}]}})
    of
        Other -> ct:fail({accepted, Other})
    catch
        error:function_clause -> ok
    end,
    ok.

%% ---------------------------------------------------------- host resources

-define(KV, ~"example:kv/store").
-define(HC, wasmtime_component).

%% example:kv/store served from Erlang: a bucket is a host resource, a handle
%% from host_new/2 with its items behind it.
kv_imports() ->
    New = fun(_Inst, [Name]) -> {ok, [?HC:host_new(bucket, {Name, []})]} end,
    #{
        {?KV, ~"[constructor]bucket"} => New,
        {?KV, ~"open"} => New,
        {?KV, ~"[method]bucket.put"} => fun(_Inst, [H, Item]) ->
            {ok, {bucket, {Name, Items}}} = ?HC:host_get(H),
            ok = ?HC:host_update(H, {Name, [Item | Items]}),
            {ok, []}
        end,
        {?KV, ~"[method]bucket.count"} => fun(_Inst, [H]) ->
            {ok, {bucket, {_, Items}}} = ?HC:host_get(H),
            {ok, [length(Items)]}
        end,
        {?KV, ~"describe"} => fun(_Inst, [H]) ->
            {ok, {bucket, {Name, Items}}} = ?HC:host_get(H),
            {ok, [iolist_to_binary([Name, $:, lists:join($,, lists:reverse(Items))])]}
        end,
        %% the guest gives the handle back for good: the host drops it
        {?KV, ~"close"} => fun(_Inst, [H]) ->
            {ok, {bucket, {_, Items}}} = ?HC:host_get(H),
            ok = ?HC:host_drop(H),
            {ok, [length(Items)]}
        end
    }.

host_resources(Config) ->
    [] = ?HC:host_live(),
    Inst = instance(Config, "hostres", #{imports => kv_imports(), wasi => #{}}),
    %% made, used through own and borrow, dropped by the guest: nothing left
    {ok, ~"fruit:apple,pear 2"} = wasmtime:call(Inst, ~"fill", [~"fruit", [~"apple", ~"pear"]]),
    [] = ?HC:host_live(),
    {ok, ~"empty: 0"} = wasmtime:call(Inst, ~"fill", [~"empty", []]),
    %% an owned handle handed back to a host function
    {ok, 1} = wasmtime:call(Inst, ~"fill-and-close", [~"tmp"]),
    [] = ?HC:host_live(),
    %% kept by the guest across calls
    {ok, undefined} = wasmtime:call(Inst, ~"keep", [~"long"]),
    [Kept] = ?HC:host_live(),
    {ok, {bucket, {~"long", [~"kept"]}}} = ?HC:host_get(Kept),
    {ok, 1} = wasmtime:call(Inst, ~"kept", []),
    %% the host changes what stands behind the handle
    ok = ?HC:host_update(Kept, {~"long", [~"a", ~"b", ~"c"]}),
    {ok, 3} = wasmtime:call(Inst, ~"kept", []),
    {ok, undefined} = wasmtime:call(Inst, ~"forget", []),
    [] = ?HC:host_live(),
    {ok, 0} = wasmtime:call(Inst, ~"kept", []),
    %% handles are not reused, and the table functions take a miss
    H = ?HC:host_new(other, x, origin),
    true = H > Kept,
    error = ?HC:host_get(Kept),
    ok = ?HC:host_update(Kept, y),
    ok = ?HC:host_drop(Kept),
    ok = ?HC:host_drop(H),
    [] = ?HC:host_live(),
    ok.

%% A fun under "[resource-drop]<name>" is told instead of the default drop.
host_resource_drop_hook(Config) ->
    Self = self(),
    Imports = (kv_imports())#{
        {?KV, ~"[resource-drop]bucket"} => fun(_Inst, [H]) ->
            Self ! {dropped, ?HC:host_get(H)},
            ok = ?HC:host_drop(H),
            {ok, []}
        end
    },
    Inst = instance(Config, "hostres", #{imports => Imports, wasi => #{}}),
    {ok, ~"x:y 1"} = wasmtime:call(Inst, ~"fill", [~"x", [~"y"]]),
    receive
        {dropped, {ok, {bucket, {~"x", [~"y"]}}}} -> ok
    after 1000 -> ct:fail(no_drop)
    end,
    [] = ?HC:host_live(),
    %% a handle the host never made is a host error, not a crash
    Bad = (kv_imports())#{{?KV, ~"open"} => fun(_Inst, [_]) -> {ok, [not_a_handle]} end},
    Inst2 = instance(Config, "hostres", #{imports => Bad, wasi => #{}}),
    {error, #{class := trap}} = wasmtime:call(Inst2, ~"fill-and-close", [~"x"]),
    %% destroying an instance that still holds a handle tells nobody: the
    %% entry stays for the host to drop
    Inst3 = instance(Config, "hostres", #{imports => kv_imports(), wasi => #{}}),
    {ok, undefined} = wasmtime:call(Inst3, ~"keep", [~"left"]),
    [Left] = ?HC:host_live(),
    ok = wasmtime:destroy(Inst3),
    [Left] = ?HC:host_live(),
    ok = ?HC:host_drop(Left),
    ok.

%% The table belongs to the process that serves the host calls.
host_resources_in_host_process(Config) ->
    Self = self(),
    Host = spawn_link(fun Loop() ->
        receive
            {wasmtime_host_call, _, _, _, _} = Call ->
                ok = wasmtime:handle_host_call(get(inst), Call),
                Loop();
            {set, Inst} ->
                put(inst, Inst),
                Self ! ready,
                Loop();
            {live, From} ->
                From ! {live, ?HC:host_live()},
                Loop()
        end
    end),
    Inst = instance(Config, "hostres", #{imports => kv_imports(), wasi => #{}, host => Host}),
    Host ! {set, Inst},
    receive
        ready -> ok
    end,
    {ok, undefined} = wasmtime:call(Inst, ~"keep", [~"k"]),
    [] = ?HC:host_live(),
    Host ! {live, self()},
    receive
        {live, [_]} -> ok
    end,
    {ok, undefined} = wasmtime:call(Inst, ~"forget", []),
    Host ! {live, self()},
    receive
        {live, []} -> ok
    end,
    ok.
