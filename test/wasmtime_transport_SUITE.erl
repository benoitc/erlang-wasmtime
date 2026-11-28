%% A component's outgoing requests sent by an Erlang module
%% (wasmtime_http_transport), and the address checks made before it. Needs a
%% library with this project's patches (features/0, wasi_http_transport).
-module(wasmtime_transport_SUITE).
-behaviour(wasmtime_http_transport).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([request/2]).
-export([
    helpers/1,
    request_reaches_the_transport/1,
    body_reaches_the_transport/1,
    run_command_takes_it/1,
    served_handler_uses_it/1,
    error_codes_reach_the_guest/1,
    grant_is_checked_first/1,
    names_need_resolve/1,
    response_is_bounded/1,
    failing_transport_fails_the_call/1,
    no_call_into_the_instance/1,
    runs_in_the_host_process/1,
    caller_timeout_ends_the_request/1
]).

all() -> [helpers, {group, transported}].

groups() ->
    [
        {transported, [], [
            request_reaches_the_transport,
            body_reaches_the_transport,
            run_command_takes_it,
            served_handler_uses_it,
            error_codes_reach_the_guest,
            grant_is_checked_first,
            names_need_resolve,
            response_is_bounded,
            failing_transport_fails_the_call,
            no_call_into_the_instance,
            runs_in_the_host_process,
            caller_timeout_ends_the_request
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wasi, components], Config).

end_per_suite(_) -> ok.

init_per_group(transported, Config) ->
    case wasmtime:features() of
        #{wasi_http_transport := true} -> Config;
        #{wasi_http_transport := false} -> {skip, "this library cannot use a transport"}
    end.

end_per_group(_, _) -> ok.

%% The transport under test: what the process that runs it left in its
%% dictionary says what to do, and the request goes back to the test.
request(Request, Timeout) ->
    case get(transport) of
        undefined ->
            {error, {~"internal-error", {some, ~"no behaviour set"}}};
        {Test, Answer} ->
            Test ! {transport, self(), Request, Timeout},
            Answer(Request)
    end.

answer(Response) -> answers(fun(_) -> Response end).

answers(Fun) ->
    _ = put(transport, {self(), Fun}),
    ok.

seen() ->
    receive
        {transport, _, Request, Timeout} -> {Request, Timeout}
    after 0 -> none
    end.

guest(Config, Suite, Name) ->
    Dir = string:replace(?config(data_dir, Config), "transport_SUITE", Suite),
    {ok, Bin} = file:read_file(
        filename:join(unicode:characters_to_list(Dir), Name ++ ".component.wasm")
    ),
    Bin.

httpget(Config) -> guest(Config, "component_SUITE", "httpget").

grant() -> #{connect => [{tcp, ~"127.0.0.1", 8080}]}.

instance(Config, Args, Extra, Opts) ->
    {ok, Mod} = wasmtime:compile(httpget(Config)),
    Wasi = maps:merge(
        #{
            args => ["httpget" | Args],
            stdout => capture,
            http => grant(),
            http_transport => ?MODULE
        },
        Extra
    ),
    {ok, Inst} = wasmtime:instantiate(Mod, #{}, Opts#{wasi => Wasi}),
    Inst.

fetch(Config, Args, Extra) ->
    Inst = instance(Config, Args, Extra, #{}),
    Result = wasmtime:run(Inst, #{timeout => 10000}),
    {ok, {Out, _, _}} = wasmtime:read_output(Inst),
    ok = wasmtime:destroy(Inst),
    {Result, Out}.

fetch(Config) -> fetch(Config, ["127.0.0.1:8080", "/a?b=1"], #{}).

helpers(_) ->
    infinity = wasmtime_http_transport:deadline(infinity),
    Deadline = wasmtime_http_transport:deadline(1000),
    infinity = wasmtime_http_transport:within(undefined, infinity),
    5 = wasmtime_http_transport:within(5, Deadline),
    ?assert(wasmtime_http_transport:within(undefined, Deadline) =< 1000),
    0 = wasmtime_http_transport:within(5, wasmtime_http_transport:deadline(0)),
    true = wasmtime_http_transport:over_limit(2, #{max_body_bytes => 1}),
    false = wasmtime_http_transport:over_limit(1, #{max_body_bytes => 1}),
    [{server_name_indication, "example.com"}] =
        wasmtime_http_transport:tls_opts(~"example.com", []),
    [] = wasmtime_http_transport:tls_opts(~"10.0.0.1", []),
    ok.

request_reaches_the_transport(Config) ->
    answer({ok, 201, [{~"x-a", ~"b"}], ~"made"}),
    {ok, ~"201\n"} = fetch(Config, ["127.0.0.1:8080", "/a?b=1"], #{
        http_tls => [{verify, verify_none}]
    }),
    {Request, 30000} = seen(),
    ?assertMatch(
        #{
            method := ~"GET",
            scheme := ~"http",
            host := ~"127.0.0.1",
            address := {127, 0, 0, 1},
            port := 8080,
            path := ~"/a?b=1",
            body := <<>>,
            tls := [{verify, verify_none}],
            connect_timeout := undefined,
            max_body_bytes := 8388608
        },
        Request
    ),
    #{headers := Headers} = Request,
    ?assertEqual(~"127.0.0.1:8080", proplists:get_value(~"host", Headers)),
    ok.

body_reaches_the_transport(Config) ->
    answer({ok, 200, [], <<>>}),
    {ok, ~"200\n"} = fetch(Config, ["127.0.0.1:8080", "/", "10000", "7"], #{}),
    {#{method := ~"POST", body := Body, headers := Headers}, _} = seen(),
    ?assertEqual(binary:copy(~"b", 10000), Body),
    ?assertEqual(~"aaaaaaa", proplists:get_value(~"x-long", Headers)),
    ok.

run_command_takes_it(Config) ->
    answer({ok, 204, [], <<>>}),
    {ok, #{stdout := ~"204\n", exit_code := 0}} = wasmtime_wasi_preview2:run_command(
        httpget(Config), <<>>, #{
            args => [~"httpget", ~"127.0.0.1:8080", ~"/"],
            network => grant(),
            http_transport => ?MODULE
        }
    ),
    {#{port := 8080}, _} = seen(),
    ok.

%% A WASI 0.3 handler forwarding its request, with its body and trailers.
served_handler_uses_it(Config) ->
    answer({ok, 202, [{~"from", ~"erlang"}], ~"forwarded"}),
    {ok, 202, Headers, ~"forwarded"} = wasmtime_wasi_preview3:run_serve(
        guest(Config, "serve_SUITE", "p3_http_proxy"),
        #{
            method => ~"PUT",
            path => ~"/",
            headers => [{~"url", ~"http://127.0.0.1:8080/to"}],
            body => ~"payload"
        },
        #{network => grant(), http_transport => ?MODULE}
    ),
    ?assertEqual(~"erlang", proplists:get_value(~"from", Headers)),
    {#{method := ~"PUT", path := ~"/to", body := ~"payload"}, _} = seen(),
    ok.

error_codes_reach_the_guest(Config) ->
    [
        begin
            answer({error, {Code, Payload}}),
            {{error, _}, <<"refused: ", Printed/binary>>} = fetch(Config),
            ?assertEqual(<<"ErrorCode::", Expected/binary, "\n">>, Printed),
            {_, _} = seen()
        end
     || {Code, Payload, Expected} <- [
            {~"connection-refused", none, ~"ConnectionRefused"},
            {~"HTTP-response-body-size", {some, 7}, ~"HttpResponseBodySize(Some(7))"},
            {~"internal-error", {some, ~"why"}, ~"InternalError(Some(\"why\"))"},
            {~"no-such-code", none, ~"InternalError(None)"}
        ]
    ],
    ok.

grant_is_checked_first(Config) ->
    answer({ok, 200, [], <<>>}),
    {{error, _}, <<"refused: ErrorCode::HttpRequestDenied", _/binary>>} =
        fetch(Config, ["127.0.0.1:8081", "/"], #{}),
    none = seen(),
    ok.

names_need_resolve(Config) ->
    answer({ok, 200, [], <<>>}),
    Local = ["localhost:8080", "/"],
    {{error, _}, <<"refused: ErrorCode::HttpRequestDenied", _/binary>>} =
        fetch(Config, Local, #{}),
    none = seen(),
    {ok, _} = fetch(Config, Local, #{http => (grant())#{resolve => allow}}),
    {#{host := ~"localhost", address := {127, 0, 0, 1}}, _} = seen(),
    {{error, _}, <<"refused: ErrorCode::DnsError", _/binary>>} =
        fetch(Config, ["nowhere.invalid:8080", "/"], #{http => all}),
    none = seen(),
    ok.

response_is_bounded(Config) ->
    answer({ok, 200, [], binary:copy(~"x", 100)}),
    Bounded = #{http_max_body_bytes => 100},
    {ok, ~"200\n"} = fetch(Config, ["127.0.0.1:8080", "/"], Bounded),
    {_, _} = seen(),
    answer({ok, 200, [], binary:copy(~"x", 101)}),
    %% the guest reads the status and not the body, so the status still comes
    {ok, ~"200\n"} = fetch(Config, ["127.0.0.1:8080", "/"], Bounded),
    {#{max_body_bytes := 100}, _} = seen(),
    ok.

failing_transport_fails_the_call(Config) ->
    [
        begin
            answers(Fun),
            {{error, #{class := trap, kind := host_error, ctx := Ctx}}, <<>>} = fetch(Config),
            ?assertMatch(#{host := {~"wasi:http", ~"transport"}}, Ctx),
            {_, _} = seen()
        end
     || Fun <- [
            fun(_) -> error(boom) end,
            fun(_) -> {ok, 200, not_headers, <<>>} end,
            fun(_) -> {ok, 200, [], not_a_body} end
        ]
    ],
    ok.

no_call_into_the_instance(Config) ->
    Inst = instance(Config, ["127.0.0.1:8080", "/"], #{}, #{}),
    Self = self(),
    answers(fun(_) ->
        Self ! {called, wasmtime:run(Inst, #{timeout => 1000})},
        {ok, 200, [], <<>>}
    end),
    ok = wasmtime:run(Inst, #{timeout => 10000}),
    receive
        {called, {error, #{class := link, kind := reentrant}}} -> ok
    after 0 -> ct:fail(not_refused)
    end,
    ok = wasmtime:destroy(Inst).

runs_in_the_host_process(Config) ->
    Test = self(),
    Host = spawn(fun() ->
        _ = put(transport, {Test, fun(_) -> {ok, 200, [], <<>>} end}),
        receive
            {instance, Inst} -> host_loop(Inst)
        end
    end),
    Inst = instance(Config, ["127.0.0.1:8080", "/"], #{}, #{host => Host}),
    Host ! {instance, Inst},
    ok = wasmtime:run(Inst, #{timeout => 10000}),
    receive
        {transport, Host, _, _} -> ok
    after 0 -> ct:fail(not_in_the_host)
    end,
    exit(Host, kill),
    ok = wasmtime:destroy(Inst).

host_loop(Inst) ->
    receive
        Message ->
            _ = wasmtime:handle_host_call(Inst, Message),
            host_loop(Inst)
    end.

%% A transport that outlasts the call's timeout: the call ends when the
%% transport returns, with the timeout, and nothing is left in the mailbox.
caller_timeout_ends_the_request(Config) ->
    answers(fun(_) ->
        timer:sleep(400),
        {ok, 200, [], <<>>}
    end),
    Inst = instance(Config, ["127.0.0.1:8080", "/"], #{}, #{}),
    Result = wasmtime:run(Inst, #{timeout => 100}),
    ct:log("~p", [Result]),
    {_, _} = seen(),
    ok = wasmtime:destroy(Inst),
    receive
        Left -> ct:fail({left, Left})
    after 100 -> ok
    end.
