%% What a component may reach and how much it may ask of the host: network
%% grants as erlang_wasm's wasi_net, HTTP rules and limits, the initial
%% directory, resource_limit and transfer_limit. All but the grant parser
%% need a library with this project's patches (features/0, wasi_limits).
-module(wasmtime_grant_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([
    grants_are_read/1,
    bad_grants_are_refused/1,
    connect_rules/1,
    resolve_and_transports/1,
    mapped_addresses_match_ipv4/1,
    http_rules/1,
    http_body_limit/1,
    http_field_limit/1,
    initial_directory/1,
    host_resource_limit/1,
    transfer_limit/1,
    core_modules_are_refused/1,
    run_command_grants/1
]).

all() -> [{group, parse}, {group, patched}].

groups() ->
    [
        {parse, [], [grants_are_read, bad_grants_are_refused, core_modules_are_refused]},
        {patched, [], [
            connect_rules,
            resolve_and_transports,
            mapped_addresses_match_ipv4,
            http_rules,
            http_body_limit,
            http_field_limit,
            initial_directory,
            host_resource_limit,
            transfer_limit,
            run_command_grants
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat, wasi, components], Config).

end_per_suite(_) -> ok.

init_per_group(patched, Config) ->
    case wasmtime:features() of
        #{wasi_limits := true} -> Config;
        #{wasi_limits := false} -> {skip, "this library cannot limit what WASI grants"}
    end;
init_per_group(_, Config) ->
    Config.

end_per_group(_, _) -> ok.

%% -------------------------------------------------------------------- parse

grants_are_read(_) ->
    {ok, none} = wasmtime_net:grant(#{}),
    {ok, none} = wasmtime_net:grant(#{connect => [], resolve => deny}),
    {ok, {rules, true, false, true, Rules}} = wasmtime_net:grant(#{
        connect => [{tcp, ~"10.1.2.3/8", {80, 90}}, {udp, {127, 0, 0, 1}, 53}],
        listen => [{tcp, ~"::1", any}, {tcp, ~"::ffff:192.168.0.0/112", 1}],
        resolve => allow,
        udp => false
    }),
    [
        {0, 0, <<10, 1, 2, 3>>, 8, 80, 90},
        {1, 0, <<127, 0, 0, 1>>, 32, 53, 53},
        {0, 1, <<1:128>>, 128, 0, 65535},
        %% the mapping bits come off the prefix with the address
        {0, 1, <<192, 168, 0, 0>>, 16, 1, 1}
    ] = Rules,
    {unsupported, [max_sockets]} = wasmtime_net:grant(#{connect => [], max_sockets => 1}),
    ok.

bad_grants_are_refused(_) ->
    [
        ?assertError({bad_net_grant, _}, wasmtime_net:grant(Bad))
     || Bad <- [
            some,
            #{conect => []},
            #{connect => [{sctp, ~"10.0.0.1", 1}]},
            #{connect => [{tcp, ~"example.com", 1}]},
            #{connect => [{tcp, ~"10.0.0.0/33", 1}]},
            #{connect => [{tcp, ~"::ffff:0.0.0.0/64", 1}]},
            #{connect => [{tcp, ~"10.0.0.1", 70000}]},
            #{resolve => yes},
            #{tcp => 1}
        ]
    ],
    ok.

core_modules_are_refused(_) ->
    Mod = wasmtime_test:compile(~"(module)"),
    Refused = fun(Opts) ->
        {error, #{class := link, kind := unsupported_option}} =
            wasmtime:instantiate(Mod, #{}, Opts)
    end,
    Refused(#{resource_limit => 1}),
    Refused(#{transfer_limit => 1}),
    Refused(#{wasi => #{initial_cwd => ~"/"}}),
    Refused(#{wasi => #{http_max_body_bytes => 1}}),
    Refused(#{wasi => #{network => #{connect => [], timeout => 1}}}),
    ok.

%% ------------------------------------------------------------------ sockets

component(Config, Name) ->
    Dir = string:replace(?config(data_dir, Config), "grant_SUITE", "component_SUITE"),
    {ok, Bin} = file:read_file(
        filename:join(unicode:characters_to_list(Dir), Name ++ ".component.wasm")
    ),
    Bin.

command(Config, Name, Args, Wasi) ->
    {ok, Mod} = wasmtime:compile(component(Config, Name)),
    {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{
        wasi => Wasi#{args => [Name | Args], stdout => capture}
    }),
    Result = wasmtime:run(Inst, #{timeout => 10000}),
    {ok, {Out, _, _}} = wasmtime:read_output(Inst),
    {Result, Out}.

%% A server on the loopback answering every connection with Reply.
serve(Reply) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    Pid = spawn(fun() -> accept(L, Reply) end),
    ok = gen_tcp:controlling_process(L, Pid),
    {Pid, Port}.

accept(L, Reply) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            _ = gen_tcp:recv(S, 0, 2000),
            drain(S),
            _ = gen_tcp:send(S, Reply),
            _ = gen_tcp:close(S),
            accept(L, Reply);
        {error, _} ->
            ok
    end.

%% The rest of a request, until the client has paused.
drain(S) ->
    case gen_tcp:recv(S, 0, 200) of
        {ok, _} -> drain(S);
        {error, _} -> ok
    end.

addr(Port) -> "127.0.0.1:" ++ integer_to_list(Port).

loopback(Port) -> #{connect => [{tcp, ~"127.0.0.1", Port}]}.

connect_rules(Config) ->
    {Server, Port} = serve(~"pong\n"),
    Connect = fun(Grant) ->
        command(Config, "net", ["tcp", addr(Port)], #{network => Grant})
    end,
    {ok, ~"pong\n"} = Connect(loopback(Port)),
    {ok, ~"pong\n"} = Connect(#{connect => [{tcp, ~"127.0.0.0/8", {1, 65535}}]}),
    [
        {{error, #{ctx := #{wasi_exit := 1}}}, <<"refused: ", _/binary>>} = Connect(Grant)
     || Grant <- [
            loopback(Port + 1),
            #{connect => [{tcp, ~"10.0.0.0/8", any}]},
            #{connect => [{udp, ~"127.0.0.1", any}]},
            #{listen => [{tcp, ~"127.0.0.1", any}]},
            #{resolve => allow}
        ]
    ],
    exit(Server, kill),
    ok.

resolve_and_transports(Config) ->
    {Server, Port} = serve(~"pong\n"),
    Resolve = fun(Grant) ->
        command(Config, "net", ["resolve", "localhost"], #{network => Grant})
    end,
    {ok, ~"true\n"} = Resolve(#{resolve => allow}),
    {{error, _}, <<"refused: ", _/binary>>} = Resolve(loopback(Port)),
    %% the address is allowed and the transport is not
    {{error, _}, <<"refused: ", _/binary>>} = command(
        Config, "net", ["tcp", addr(Port)], #{network => (loopback(Port))#{tcp => false}}
    ),
    exit(Server, kill),
    ok.

mapped_addresses_match_ipv4(Config) ->
    {Server, Port} = serve(~"pong\n"),
    {ok, ~"pong\n"} = command(Config, "net", ["tcp", addr(Port)], #{
        network => #{connect => [{tcp, ~"::ffff:127.0.0.1", Port}]}
    }),
    exit(Server, kill),
    ok.

%% --------------------------------------------------------------------- HTTP

ok_response(Body) ->
    [
        "HTTP/1.1 200 OK\r\ncontent-length: ",
        integer_to_list(iolist_size(Body)),
        "\r\nconnection: close\r\n\r\n",
        Body
    ].

needs_http(Fun) ->
    case wasmtime:features() of
        #{wasi_http := true} -> Fun();
        #{wasi_http := false} -> {skip, "this library has no wasi:http"}
    end.

get(Config, Port, Wasi) ->
    command(Config, "httpget", [addr(Port), "/"], Wasi).

http_rules(Config) ->
    needs_http(fun() ->
        {Server, Port} = serve(ok_response(~"hi")),
        {ok, ~"200\n"} = get(Config, Port, #{http => loopback(Port)}),
        %% a name is resolved once, and the address it gave is what is checked
        {ok, ~"200\n"} = command(
            Config,
            "httpget",
            ["localhost:" ++ integer_to_list(Port), "/"],
            #{http => loopback(Port)}
        ),
        [
            {{error, _}, <<"refused: ErrorCode::HttpRequestDenied", _/binary>>} =
                get(Config, Port, #{http => Grant})
         || Grant <- [
                loopback(Port + 1),
                #{connect => [{tcp, ~"10.0.0.0/8", any}]},
                #{connect => [{udp, ~"127.0.0.1", any}]},
                #{resolve => allow}
            ]
        ],
        %% sockets rules grant no HTTP
        {error, #{class := link}} = wasmtime:instantiate(
            element(2, wasmtime:compile(component(Config, "httpget"))),
            #{},
            #{wasi => #{network => loopback(Port)}}
        ),
        exit(Server, kill),
        ok
    end).

%% httpget reads the status and never the body of the response, so the bound
%% on that one shows only as a response that still arrives. The body it writes
%% is refused past the limit, 8 MiB by default.
http_body_limit(Config) ->
    needs_http(fun() ->
        {Server, Port} = serve(ok_response(lists:duplicate(100000, $b))),
        Post = fun(Size, Wasi) ->
            command(
                Config,
                "httpget",
                [addr(Port), "/", integer_to_list(Size)],
                Wasi#{http => all}
            )
        end,
        {ok, ~"200\n"} = get(Config, Port, #{http => all, http_max_body_bytes => 10}),
        {ok, ~"200\n"} = Post(10000, #{}),
        {ok, ~"200\n"} = Post(10000, #{http_max_body_bytes => 10000}),
        {{error, _}, <<"refused: ", _/binary>>} = Post(10000, #{http_max_body_bytes => 9999}),
        {{error, _}, <<"refused: ", _/binary>>} = Post(8 * 1024 * 1024 + 1, #{}),
        {ok, ~"200\n"} = Post(8 * 1024 * 1024 + 1, #{http_max_body_bytes => 1 bsl 24}),
        {error, #{class := link, kind := wasi_config}} = wasmtime:instantiate(
            element(2, wasmtime:compile(component(Config, "httpget"))),
            #{},
            #{wasi => #{http => all, http_max_body_bytes => 0}}
        ),
        exit(Server, kill),
        ok
    end).

%% The bound is on the headers the guest builds.
http_field_limit(Config) ->
    needs_http(fun() ->
        {Server, Port} = serve(ok_response(~"hi")),
        Send = fun(Limit) ->
            command(
                Config,
                "httpget",
                [addr(Port), "/", "0", "2000"],
                #{http => all, http_max_field_bytes => Limit}
            )
        end,
        {ok, ~"200\n"} = Send(65536),
        %% `wasi:http` has no error for it: the guest traps
        {{error, #{class := trap}}, _} = Send(256),
        exit(Server, kill),
        ok
    end).

%% ------------------------------------------------------------------- limits

initial_directory(Config) ->
    {ok, ~"none\n"} = command(Config, "cwd", [], #{}),
    {ok, ~"/work\n"} = command(Config, "cwd", [], #{initial_cwd => ~"/work"}),
    {ok, Mod} = wasmtime:compile(component(Config, "cwd")),
    [
        {error, #{class := link, kind := wasi_config}} =
            wasmtime:instantiate(Mod, #{}, #{wasi => #{initial_cwd => Bad}})
     || Bad <- [<<255>>, <<"/a", 0, "b">>]
    ],
    ok.

host_resource_limit(Config) ->
    New = fun(_, [Name]) -> {ok, [wasmtime_component:host_new(bucket, {Name, []})]} end,
    Imports = #{
        {~"example:kv/store", ~"[constructor]bucket"} => New,
        {~"example:kv/store", ~"open"} => New,
        {~"example:kv/store", ~"[method]bucket.put"} => fun(_, [_, _]) -> {ok, []} end,
        {~"example:kv/store", ~"[method]bucket.count"} => fun(_, [_]) -> {ok, [0]} end,
        {~"example:kv/store", ~"describe"} => fun(_, [_]) -> {ok, [~""]} end,
        {~"example:kv/store", ~"close"} => fun(_, [H]) ->
            ok = wasmtime_component:host_drop(H),
            {ok, [1]}
        end
    },
    {ok, Mod} = wasmtime:compile(component(Config, "hostres")),
    {ok, Inst} = wasmtime:instantiate(Mod, Imports, #{wasi => #{}, resource_limit => 1}),
    %% `keep` opens a bucket before it lets go of the one it has
    {ok, undefined} = wasmtime:call(Inst, ~"keep", [~"first"]),
    {error, #{class := trap, kind := resource_limit_reached, ctx := #{limit := 1}}} =
        wasmtime:call(Inst, ~"keep", [~"second"]),
    [wasmtime_component:host_drop(H) || H <- wasmtime_component:host_live()],
    ok.

%% (list u8) -> (list u8), growing memory as asked.
echo() ->
    ~"""
    (component
      (core module $m
        (memory (export "mem") 1)
        (global $top (mut i32) (i32.const 1024))
        (func (export "realloc") (param i32 i32 i32 i32) (result i32)
          (local $p i32) (local $end i32)
          (local.set $p (i32.and (i32.add (global.get $top) (i32.const 7)) (i32.const -8)))
          (local.set $end (i32.add (local.get $p) (local.get 3)))
          (if (i32.gt_u (local.get $end) (i32.mul (memory.size) (i32.const 65536)))
            (then (drop (memory.grow (i32.add (i32.div_u
              (i32.sub (local.get $end) (i32.mul (memory.size) (i32.const 65536)))
              (i32.const 65536)) (i32.const 1))))))
          (global.set $top (local.get $end))
          (local.get $p))
        (func (export "echo") (param $p i32) (param $n i32) (result i32)
          (i32.store (i32.const 0) (local.get $p))
          (i32.store (i32.const 4) (local.get $n))
          (i32.const 0))
        (func (export "reset") (param i32) (global.set $top (i32.const 1024))))
      (core instance $i (instantiate $m))
      (func (export "echo") (param "b" (list u8)) (result (list u8))
        (canon lift (core func $i "echo") (memory (core memory $i "mem"))
          (realloc (core func $i "realloc")) (post-return (core func $i "reset")))))
    """.

transfer_limit(_) ->
    {ok, Mod} = wasmtime:compile({wat, echo()}),
    Big = binary:copy(~"x", 4 * 1024 * 1024),
    {ok, Default} = wasmtime:instantiate(Mod),
    {error, #{class := exhaustion, kind := hostcall_fuel}} =
        wasmtime:call(Default, ~"echo", [Big]),
    {ok, Wide} = wasmtime:instantiate(Mod, #{}, #{transfer_limit => 1 bsl 29}),
    {ok, Big} = wasmtime:call(Wide, ~"echo", [Big]),
    {ok, Narrow} = wasmtime:instantiate(Mod, #{}, #{transfer_limit => 1024}),
    {error, #{class := exhaustion, kind := hostcall_fuel}} =
        wasmtime:call(Narrow, ~"echo", [binary:copy(~"x", 1024)]),
    ok.

run_command_grants(Config) ->
    {Server, Port} = serve(~"pong\n"),
    {ok, #{stdout := ~"pong\n", exit_code := 0}} = wasmtime_wasi_preview2:run_command(
        component(Config, "net"), <<>>, #{
            args => [~"net", ~"tcp", list_to_binary(addr(Port))], network => loopback(Port)
        }
    ),
    {ok, #{exit_code := 1}} = wasmtime_wasi_preview2:run_command(
        component(Config, "net"), <<>>, #{
            args => [~"net", ~"tcp", list_to_binary(addr(Port))], network => loopback(Port + 1)
        }
    ),
    {ok, #{stdout := ~"/srv\n"}} = wasmtime_wasi_preview2:run_command(
        component(Config, "cwd"), <<>>, #{initial_cwd => ~"/srv"}
    ),
    exit(Server, kill),
    ok.
