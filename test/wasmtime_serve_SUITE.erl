%% Requests given to wasi:http handlers: run_serve for WASI 0.2 and 0.3, and
%% the parts a response arrives in (wasmtime_http_serve:stream/4). Needs a
%% library with this project's patches (features/0, wasi_http_serve).
-module(wasmtime_serve_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([
    hello_p2/1,
    request_reaches_p2/1,
    env_and_headers_p2/1,
    no_response_p2/1,
    printing_does_not_disturb/1,
    hello_p3/1,
    echo_p3/1,
    echo_host_to_host/1,
    post_return_work_runs/1,
    forbidden_headers_are_dropped/1,
    body_limit/1,
    streaming_parts/1,
    slow_reader_holds_the_guest/1,
    emit_failure_ends_the_request/1,
    timeout_stops_a_handler/1,
    caller_death_ends_the_request/1,
    parts_go_to_the_caller/1,
    outgoing_needs_a_grant/1,
    no_handler/1,
    bad_requests/1,
    refused_options/1,
    prepared_component/1,
    unpatched_is_refused/1
]).

-define(BODY, ~"hello body").

all() -> [{group, served}, unpatched_is_refused].

groups() ->
    [
        {served, [], [
            hello_p2,
            request_reaches_p2,
            env_and_headers_p2,
            no_response_p2,
            printing_does_not_disturb,
            hello_p3,
            echo_p3,
            echo_host_to_host,
            post_return_work_runs,
            forbidden_headers_are_dropped,
            body_limit,
            streaming_parts,
            slow_reader_holds_the_guest,
            emit_failure_ends_the_request,
            timeout_stops_a_handler,
            caller_death_ends_the_request,
            parts_go_to_the_caller,
            outgoing_needs_a_grant,
            no_handler,
            bad_requests,
            refused_options,
            prepared_component
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wasi, components], Config).

end_per_suite(_) -> ok.

init_per_group(served, Config) ->
    case wasmtime:features() of
        #{wasi_http_serve := true} -> Config;
        #{wasi_http_serve := false} -> {skip, "this library cannot serve HTTP requests"}
    end.

end_per_group(_, _) -> ok.

guest(Config, Name) ->
    {ok, Bin} = file:read_file(
        filename:join(?config(data_dir, Config), Name ++ ".component.wasm")
    ),
    Bin.

request() -> request(#{}).

request(Extra) -> maps:merge(#{method => ~"GET", path => ~"/"}, Extra).

serve(Config, Name) -> serve(Config, Name, request(), #{}).

serve(Config, Name, Request, Options) ->
    wasmtime_wasi_preview2:run_serve(guest(Config, Name), Request, Options).

echo(Config, Headers) ->
    wasmtime_wasi_preview3:run_serve(
        guest(Config, "p3_http_echo"),
        request(#{
            method => ~"post",
            headers => Headers,
            body => ?BODY,
            trailers => [{~"fizz", ~"buzz"}]
        }),
        #{}
    ).

%% ----------------------------------------------------------------- WASI 0.2

hello_p2(Config) ->
    {ok, 200, _, ~"Hello, WASI!"} = serve(Config, "p2_cli_serve_hello_world"),
    ok.

%% The program traps unless it sees http://localhost.
request_reaches_p2(Config) ->
    {ok, 200, _, _} = serve(Config, "p2_cli_serve_authority_and_scheme"),
    {error, no_response} = serve(
        Config,
        "p2_cli_serve_authority_and_scheme",
        request(#{authority => ~"example.com"}),
        #{}
    ),
    ok.

env_and_headers_p2(Config) ->
    {ok, 200, Headers, <<>>} = serve(
        Config,
        "p2_cli_serve_echo_env",
        request(#{headers => [{~"env", ~"GREETING"}]}),
        #{env => [{~"GREETING", ~"bonjour"}]}
    ),
    ?assertEqual(~"bonjour", proplists:get_value(~"env", Headers)),
    ok.

no_response_p2(Config) ->
    {error, no_response} = serve(Config, "p2_cli_serve_return_before_set"),
    {error, no_response} = serve(Config, "p2_cli_serve_trap_before_set"),
    ok.

printing_does_not_disturb(Config) ->
    {ok, 200, _, <<>>} = serve(Config, "p2_cli_serve_with_print"),
    ok.

%% ----------------------------------------------------------------- WASI 0.3

hello_p3(Config) ->
    {ok, 200, [], ~"Hello, WASI!"} = serve(Config, "p3_cli_serve_hello_world"),
    ok.

echo_p3(Config) ->
    ?assertEqual(
        {ok, 200, [{~"foo", ~"bar"}], ?BODY, [{~"fizz", ~"buzz"}]},
        echo(Config, [{~"foo", ~"bar"}])
    ),
    ok.

%% The handler answers with the request's own body stream and trailers.
echo_host_to_host(Config) ->
    Headers = [{~"foo", ~"bar"}, {~"x-host-to-host", ~"true"}],
    ?assertEqual(
        {ok, 200, Headers, ?BODY, [{~"fizz", ~"buzz"}]},
        echo(Config, Headers)
    ),
    ok.

%% What the handler leaves running prints after its response.
post_return_work_runs(Config) ->
    {ok, Mod} = wasmtime:compile(guest(Config, "p3_cli_serve_post_return")),
    {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{
        wasi => #{http => deny, stdout => capture}
    }),
    Wire = {~"GET", ~"http", ~"localhost", ~"/", [], <<>>, []},
    {ok, {served, p3, _}} = wasmtime:serve_http(Inst, Wire, fun(_) -> true end),
    {ok, {~"please see me\n", _, _}} = wasmtime:read_output(Inst),
    ok.

forbidden_headers_are_dropped(Config) ->
    {ok, 200, Headers, _, _} = echo(Config, [
        {~"host", ~"victim.internal"}, {~"connection", ~"close"}, {~"foo", ~"bar"}
    ]),
    ?assertEqual([{~"foo", ~"bar"}], Headers),
    ok.

body_limit(Config) ->
    Echo = fun(Max) ->
        wasmtime_wasi_preview3:run_serve(
            guest(Config, "p3_http_echo"),
            request(#{body => ?BODY}),
            #{http_max_body_bytes => Max}
        )
    end,
    {ok, 200, _, ?BODY} = Echo(byte_size(?BODY)),
    {error, {~"HTTP-response-body-size", {some, 4}}} = Echo(4),
    ok.

%% ---------------------------------------------------------------- streaming

parts(Config, Request, Emit) ->
    wasmtime_http_serve:stream(guest(Config, "p3_http_echo"), Request, #{}, Emit).

streaming_parts(Config) ->
    Self = self(),
    Body = binary:copy(~"x", 1024 * 1024),
    streamed = parts(Config, request(#{body => Body}), fun(Part) ->
        Self ! {part, Part},
        ok
    end),
    [{head, 200, []} | Rest] = received(),
    {Chunks, [{done, []}]} = lists:splitwith(fun(P) -> element(1, P) =:= chunk end, Rest),
    ?assert(length(Chunks) > 1),
    ?assertEqual(Body, iolist_to_binary([C || {chunk, C} <- Chunks])),
    ok.

received() ->
    receive
        {part, Part} -> [Part | received()]
    after 0 -> []
    end.

%% A reader slower than the host timeout of a host function keeps the request:
%% only the call's own timeout bounds it.
slow_reader_holds_the_guest(Config) ->
    {ok, Mod} = wasmtime:compile(guest(Config, "p3_cli_serve_hello_world")),
    {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{
        wasi => #{http => deny}, host_timeout => 50
    }),
    Wire = {~"GET", ~"http", ~"localhost", ~"/", [], <<>>, []},
    Slow = fun(_) ->
        timer:sleep(150),
        true
    end,
    {ok, {served, p3, _}} = wasmtime:serve_http(Inst, Wire, Slow),
    ok.

%% A handler whose response failed runs nothing more.
emit_failure_ends_the_request(Config) ->
    {error, #{class := trap, kind := host_error}} = parts(
        Config, request(#{body => ?BODY}), fun
            ({head, _, _}) -> ok;
            (_) -> error(client_gone)
        end
    ),
    ok.

timeout_stops_a_handler(Config) ->
    [
        {error, #{kind := timeout}} = serve(Config, Name, request(), #{timeout => 300})
     || Name <- ["p2_cli_serve_sleep", "p3_cli_serve_sleep"]
    ],
    ok.

%% A caller that dies while it holds a part stops the instance's request, and
%% the instance runs nothing more.
caller_death_ends_the_request(Config) ->
    {ok, Mod} = wasmtime:compile(guest(Config, "p3_cli_serve_hello_world")),
    {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{wasi => #{http => deny}}),
    Wire = {~"GET", ~"http", ~"localhost", ~"/", [], <<>>, []},
    Self = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        wasmtime:serve_http(Inst, Wire, fun(_) ->
            Self ! holding,
            timer:sleep(infinity)
        end)
    end),
    receive
        holding -> ok
    after 5000 -> ct:fail(no_part)
    end,
    exit(Pid, kill),
    receive
        {'DOWN', Mon, process, Pid, killed} -> ok
    end,
    {error, #{class := link, kind := interrupted_instance}} =
        wasmtime:serve_http(Inst, Wire, fun(_) -> true end),
    ok = wasmtime:destroy(Inst).

parts_go_to_the_caller(Config) ->
    {ok, Mod} = wasmtime:compile(guest(Config, "p3_cli_serve_hello_world")),
    Host = spawn(fun() -> timer:sleep(infinity) end),
    {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{wasi => #{http => deny}, host => Host}),
    Wire = {~"GET", ~"http", ~"localhost", ~"/", [], <<>>, []},
    {ok, {served, p3, _}} = wasmtime:serve_http(Inst, Wire, fun(_) -> true end),
    exit(Host, kill),
    ok = wasmtime:destroy(Inst).

%% The proxy forwards to the URL its `url' header names.
outgoing_needs_a_grant(Config) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    Server = spawn(fun() -> accept(L) end),
    ok = gen_tcp:controlling_process(L, Server),
    Url = iolist_to_binary(["http://127.0.0.1:", integer_to_binary(Port), "/"]),
    Forward = fun(Options) ->
        serve(Config, "p3_http_proxy", request(#{headers => [{~"url", Url}]}), Options)
    end,
    {ok, 204, _, <<>>} = Forward(#{network => #{connect => [{tcp, ~"127.0.0.1", Port}]}}),
    [
        {error, {~"HTTP-request-denied", undefined}} = Forward(Options)
     || Options <- [#{}, #{network => #{connect => [{tcp, ~"10.0.0.0/8", any}]}}]
    ],
    exit(Server, kill),
    ok.

accept(L) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            _ = gen_tcp:recv(S, 0, 2000),
            ok = gen_tcp:send(S, ~"HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n"),
            ok = gen_tcp:close(S),
            accept(L);
        {error, _} ->
            ok
    end.

%% ------------------------------------------------------------------ refusals

no_handler(Config) ->
    Dir = string:replace(?config(data_dir, Config), "serve_SUITE", "component_SUITE"),
    {ok, Bin} = file:read_file(
        filename:join(unicode:characters_to_list(Dir), "httpget.component.wasm")
    ),
    {error, no_incoming_handler} = wasmtime_wasi_preview2:run_serve(Bin, request(), #{}),
    ok.

bad_requests(Config) ->
    [
        {error, #{class := link, kind := badarg}} =
            serve(Config, "p3_cli_serve_hello_world", Bad, #{})
     || Bad <- [
            #{path => ~"/"},
            request(#{path => "/"}),
            request(#{path => ~"not a path"}),
            request(#{method => ~"G T"}),
            request(#{authority => ~"a b"}),
            request(#{headers => [{~"bad name", ~"v"}]}),
            request(#{headers => [{~"n", ~"line\r\nbreak"}]}),
            request(#{trailers => [{name, ~"v"}]}),
            request(#{body => body})
        ]
    ],
    ok.

refused_options(Config) ->
    [
        {error, #{class := link, kind := unsupported_option}} =
            serve(Config, "p2_cli_serve_hello_world", request(), Options)
     || Options <- [#{stdout => capture}, #{stdin_dir => ~"/"}]
    ],
    ok.

prepared_component(Config) ->
    {ok, Prepared} = wasmtime_component:prepare(guest(Config, "p2_cli_serve_hello_world")),
    {ok, 200, _, _} = wasmtime_wasi_preview2:run_serve(Prepared, request(), #{}),
    {ok, 200, _, _} = wasmtime_wasi_preview2:run_serve(Prepared, request(), #{}),
    ok.

unpatched_is_refused(Config) ->
    case wasmtime:features() of
        #{wasi_http_serve := false} ->
            {error, #{class := link, kind := unavailable}} =
                serve(Config, "p2_cli_serve_hello_world");
        #{wasi_http_serve := true} ->
            {skip, "this library serves HTTP"}
    end.
