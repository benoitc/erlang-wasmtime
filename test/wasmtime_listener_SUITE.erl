%% wasmtime_http_listener over raw sockets: the responses of WASI 0.2 and 0.3
%% handlers, and what it does with requests that are malformed, too large, too
%% slow or meant to be read two ways (RFC 9112). Needs a library with this
%% project's patches (features/0, wasi_http_serve).
-module(wasmtime_listener_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([
    p2_response_has_a_length/1,
    p3_response_is_chunked/1,
    trailers_both_ways/1,
    declared_length_is_kept/1,
    head_has_no_body/1,
    http_1_0_ends_with_the_connection/1,
    pipelined_requests/1,
    requests_per_connection_are_capped/1,
    continue_is_answered/1,
    authority_comes_from_the_target/1,
    guest_failures_are_500/1,
    slow_guests_are_504/1,
    large_bodies_are_413/1,
    slow_requests_are_408/1,
    malformed_requests_are_refused/1,
    nothing_follows_a_refusal/1,
    bytes_that_are_not_utf8/1,
    requests_the_guest_cannot_be_given/1,
    extra_connections_are_503/1,
    a_slow_reader_is_cut_off/1,
    a_client_that_leaves/1,
    stop_closes_everything/1,
    the_listener_ends_with_its_owner/1,
    bad_options_are_refused/1,
    what_cannot_be_written/1
]).

-define(HOST, "host: localhost\r\n").

all() -> [what_cannot_be_written, {group, listening}].

groups() ->
    [
        {listening, [], [
            p2_response_has_a_length,
            p3_response_is_chunked,
            trailers_both_ways,
            declared_length_is_kept,
            head_has_no_body,
            http_1_0_ends_with_the_connection,
            pipelined_requests,
            requests_per_connection_are_capped,
            continue_is_answered,
            authority_comes_from_the_target,
            guest_failures_are_500,
            slow_guests_are_504,
            large_bodies_are_413,
            slow_requests_are_408,
            malformed_requests_are_refused,
            nothing_follows_a_refusal,
            bytes_that_are_not_utf8,
            requests_the_guest_cannot_be_given,
            extra_connections_are_503,
            a_slow_reader_is_cut_off,
            a_client_that_leaves,
            stop_closes_everything,
            the_listener_ends_with_its_owner,
            bad_options_are_refused
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wasi, components], Config).

end_per_suite(_) -> ok.

init_per_group(listening, Config) ->
    case wasmtime:features() of
        #{wasi_http_serve := true} -> Config;
        #{wasi_http_serve := false} -> {skip, "this library cannot serve HTTP requests"}
    end.

end_per_group(_, _) -> ok.

guest(Config, Name) ->
    Dir = string:replace(?config(data_dir, Config), "listener_SUITE", "serve_SUITE"),
    {ok, Bin} = file:read_file(
        filename:join(unicode:characters_to_list(Dir), Name ++ ".component.wasm")
    ),
    Bin.

with(Config, Name, Fun) -> with(Config, Name, #{}, Fun).

with(Config, Name, Options, Fun) ->
    {ok, Listener} = wasmtime_http_listener:start(Options#{component => guest(Config, Name)}),
    [_, Port] = binary:split(wasmtime_http_listener:address(Listener), ~":"),
    try
        Fun(binary_to_integer(Port))
    after
        ok = wasmtime_http_listener:stop(Listener)
    end.

connect(Port) ->
    {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}]),
    Socket.

%% Everything the server sends until it closes, or pauses for Wait ms.
read(Socket) -> read(Socket, 5000, <<>>).

read(Socket, Wait, Acc) ->
    case gen_tcp:recv(Socket, 0, Wait) of
        {ok, Data} -> read(Socket, Wait, <<Acc/binary, Data/binary>>);
        {error, closed} -> {closed, Acc};
        {error, Reason} -> {Reason, Acc}
    end.

%% Until Mark has arrived.
until(Socket, Mark) -> until(Socket, Mark, <<>>).

until(Socket, Mark, Acc) ->
    case binary:match(Acc, Mark) of
        nomatch ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 5000),
            until(Socket, Mark, <<Acc/binary, Data/binary>>);
        _ ->
            Acc
    end.

%% Send Request on a new connection and read to its close.
exchange(Port, Request) ->
    Socket = connect(Port),
    ok = gen_tcp:send(Socket, Request),
    Reply = read(Socket),
    ok = gen_tcp:close(Socket),
    Reply.

closing_get() -> "GET / HTTP/1.1\r\n" ?HOST "connection: close\r\n\r\n".

status(<<"HTTP/1.1 ", Status:3/binary, _/binary>>) -> binary_to_integer(Status).

split(Reply) ->
    [Head, Body] = binary:split(Reply, ~"\r\n\r\n"),
    {string:lowercase(Head), Body}.

has(Head, Line) -> binary:match(Head, Line) =/= nomatch.

%% ---------------------------------------------------------------- responses

p2_response_has_a_length(Config) ->
    with(Config, "p2_cli_serve_hello_world", fun(Port) ->
        Socket = connect(Port),
        %% the connection stays for a second request
        [
            begin
                ok = gen_tcp:send(Socket, "GET / HTTP/1.1\r\n" ?HOST "\r\n"),
                {Head, Body} = split(until(Socket, ~"Hello, WASI!")),
                200 = binary_to_integer(binary:part(Head, 9, 3)),
                ?assert(has(Head, ~"content-length: 12")),
                ?assert(has(Head, ~"date: ")),
                ?assertNot(has(Head, ~"chunked")),
                ?assertEqual(~"Hello, WASI!", Body)
            end
         || _ <- [1, 2]
        ],
        ok = gen_tcp:close(Socket)
    end).

p3_response_is_chunked(Config) ->
    with(Config, "p3_cli_serve_hello_world", fun(Port) ->
        {closed, Reply} = exchange(Port, closing_get()),
        {Head, Body} = split(Reply),
        200 = status(Reply),
        ?assert(has(Head, ~"transfer-encoding: chunked")),
        ?assert(has(Head, ~"connection: close")),
        ?assertEqual(~"C\r\nHello, WASI!\r\n0\r\n\r\n", Body)
    end).

trailers_both_ways(Config) ->
    with(Config, "p3_http_echo", fun(Port) ->
        {closed, Reply} = exchange(Port, [
            "POST / HTTP/1.1\r\n"
            ?HOST
            "foo: bar\r\ntransfer-encoding: chunked\r\n"
            "connection: close\r\n\r\n",
            "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nfizz: buzz\r\ncontent-length: 9\r\n\r\n"
        ]),
        {Head, Body} = split(Reply),
        ?assert(has(Head, ~"foo: bar")),
        ?assertNotEqual(nomatch, binary:match(Body, ~"hello world")),
        %% a trailer that would reframe the message is dropped on the way in
        ?assertMatch({_, _}, binary:match(Body, ~"\r\n0\r\nfizz: buzz\r\n\r\n"))
    end).

declared_length_is_kept(Config) ->
    with(Config, "p3_http_echo", fun(Port) ->
        {closed, Reply} = exchange(Port, [
            "POST / HTTP/1.1\r\n" ?HOST "content-length: 5\r\nconnection: close\r\n\r\nhello"
        ]),
        {Head, Body} = split(Reply),
        ?assert(has(Head, ~"content-length: 5")),
        ?assertNot(has(Head, ~"chunked")),
        ?assertEqual(~"hello", Body)
    end).

head_has_no_body(Config) ->
    [
        with(Config, Name, fun(Port) ->
            {closed, Reply} = exchange(
                Port, "HEAD / HTTP/1.1\r\n" ?HOST "connection: close\r\n\r\n"
            ),
            200 = status(Reply),
            {Head, <<>>} = split(Reply),
            ?assertNot(has(Head, ~"chunked"))
        end)
     || Name <- ["p2_cli_serve_hello_world", "p3_cli_serve_hello_world"]
    ].

http_1_0_ends_with_the_connection(Config) ->
    with(Config, "p3_cli_serve_hello_world", fun(Port) ->
        {closed, Reply} = exchange(Port, "GET / HTTP/1.0\r\n\r\n"),
        {Head, Body} = split(Reply),
        ?assert(has(Head, ~"connection: close")),
        ?assertNot(has(Head, ~"chunked")),
        ?assertEqual(~"Hello, WASI!", Body)
    end).

pipelined_requests(Config) ->
    with(Config, "p2_cli_serve_hello_world", fun(Port) ->
        {closed, Reply} = exchange(Port, [
            "\r\nGET / HTTP/1.1\r\n" ?HOST "\r\n", closing_get()
        ]),
        ?assertEqual(2, length(binary:matches(Reply, ~"Hello, WASI!")))
    end).

requests_per_connection_are_capped(Config) ->
    with(Config, "p2_cli_serve_hello_world", fun(Port) ->
        Requests = lists:duplicate(101, "GET / HTTP/1.1\r\n" ?HOST "\r\n"),
        {_, Reply} = exchange(Port, Requests),
        ?assertEqual(100, length(binary:matches(Reply, ~"HTTP/1.1 200"))),
        ?assertEqual(1, length(binary:matches(Reply, ~"connection: close")))
    end).

continue_is_answered(Config) ->
    with(Config, "p3_http_echo", fun(Port) ->
        Socket = connect(Port),
        ok = gen_tcp:send(Socket, [
            "POST / HTTP/1.1\r\n"
            ?HOST
            "content-length: 2\r\nexpect: 100-continue\r\n"
            "connection: close\r\n\r\n"
        ]),
        <<"HTTP/1.1 100 Continue\r\n\r\n">> = until(Socket, ~"\r\n\r\n"),
        ok = gen_tcp:send(Socket, "ok"),
        {closed, Reply} = read(Socket),
        200 = status(Reply)
    end).

%% The program traps unless it is told it is `localhost`.
authority_comes_from_the_target(Config) ->
    with(Config, "p2_cli_serve_authority_and_scheme", fun(Port) ->
        Status = fun(Request) ->
            {closed, Reply} = exchange(Port, [Request, "connection: close\r\n\r\n"]),
            status(Reply)
        end,
        200 = Status("GET / HTTP/1.1\r\nhost: localhost\r\n"),
        500 = Status("GET / HTTP/1.1\r\nhost: example.com\r\n"),
        %% an absolute target wins over Host (RFC 9112 section 3.2.2)
        200 = Status("GET http://localhost/ HTTP/1.1\r\nhost: example.com\r\n")
    end).

%% ------------------------------------------------------------------ failure

guest_failures_are_500(Config) ->
    [
        with(Config, Name, fun(Port) ->
            Socket = connect(Port),
            %% the listener keeps the connection: the request was read
            [
                begin
                    ok = gen_tcp:send(Socket, "GET / HTTP/1.1\r\n" ?HOST "\r\n"),
                    500 = status(until(Socket, ~"\r\n\r\n"))
                end
             || _ <- [1, 2]
            ],
            ok = gen_tcp:close(Socket)
        end)
     || Name <- ["p2_cli_serve_trap_before_set", "p2_cli_serve_return_before_set"]
    ].

slow_guests_are_504(Config) ->
    [
        with(Config, Name, #{request_timeout => 500}, fun(Port) ->
            {closed, Reply} = exchange(Port, closing_get()),
            504 = status(Reply)
        end)
     || Name <- ["p2_cli_serve_sleep", "p3_cli_serve_sleep"]
    ].

large_bodies_are_413(Config) ->
    with(Config, "p3_http_echo", #{max_body_bytes => 4}, fun(Port) ->
        Post = fun(Rest) -> exchange(Port, ["POST / HTTP/1.1\r\n" ?HOST, Rest]) end,
        {closed, Fits} = Post("content-length: 4\r\nconnection: close\r\n\r\nfour"),
        200 = status(Fits),
        %% refused on its length alone, without asking for the body
        {closed, Declared} = Post("content-length: 5\r\nexpect: 100-continue\r\n\r\n"),
        413 = status(Declared),
        {closed, Chunked} = Post(
            "transfer-encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
        ),
        413 = status(Chunked),
        {closed, Huge} = Post("transfer-encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFF\r\n"),
        413 = status(Huge)
    end).

slow_requests_are_408(Config) ->
    with(Config, "p3_http_echo", #{request_timeout => 300}, fun(Port) ->
        {closed, Head} = exchange(Port, "GET / HTTP/1.1\r\nhost: loc"),
        408 = status(Head),
        {closed, Line} = exchange(Port, "GET / HT"),
        408 = status(Line),
        {closed, Body} = exchange(
            Port, "POST / HTTP/1.1\r\n" ?HOST "content-length: 10\r\n\r\nabc"
        ),
        408 = status(Body),
        %% an idle connection is closed without a word
        {closed, <<>>} = exchange(Port, "")
    end).

malformed() ->
    Long = lists:duplicate(9000, $a),
    Get = fun(Fields) -> ["GET / HTTP/1.1\r\n" ?HOST, Fields, "\r\n"] end,
    Post = fun(Fields) -> ["POST / HTTP/1.1\r\n" ?HOST, Fields, "\r\n"] end,
    Chunks = fun(Bytes) -> Post(["transfer-encoding: chunked\r\n\r\n", Bytes]) end,
    [
        {no_host, 400, "GET / HTTP/1.1\r\n\r\n"},
        {two_hosts, 400, Get("host: other\r\n")},
        {bad_host, 400, "GET / HTTP/1.1\r\nhost: a b\r\n\r\n"},
        {named_port, 400, "GET / HTTP/1.1\r\nhost: localhost:port\r\n\r\n"},
        {large_port, 400, "GET / HTTP/1.1\r\nhost: localhost:65536\r\n\r\n"},
        {two_ports, 400, "GET / HTTP/1.1\r\nhost: a:1:2\r\n\r\n"},
        {absolute_without_host, 400, "GET http:/// HTTP/1.1\r\n" ?HOST "\r\n"},
        {userinfo, 400, "GET http://u@localhost/ HTTP/1.1\r\n" ?HOST "\r\n"},
        {length_and_coding, 400, Post("content-length: 1\r\ntransfer-encoding: chunked\r\n")},
        {two_lengths, 400, Post("content-length: 1\r\ncontent-length: 1\r\n")},
        {listed_lengths, 400, Post("content-length: 1, 1\r\n")},
        {signed_length, 400, Post("content-length: +1\r\n")},
        {hex_length, 400, Post("content-length: 0x1\r\n")},
        {long_length, 400, Post("content-length: 99999999999999999999\r\n")},
        {chunked_not_last, 400, Post("transfer-encoding: chunked, gzip\r\n")},
        {chunked_twice, 400, Post("transfer-encoding: chunked\r\ntransfer-encoding: chunked\r\n")},
        {other_coding, 501, Post("transfer-encoding: gzip, chunked\r\n")},
        {coding_in_1_0, 400, "POST / HTTP/1.0\r\ntransfer-encoding: chunked\r\n\r\n"},
        {bare_lf, 400, "GET / HTTP/1.1\nhost: localhost\n\n"},
        {bare_lf_in_field, 400, ["GET / HTTP/1.1\r\n", "host: localhost\nx: y\r\n\r\n"]},
        {cr_in_value, 400, Get("x: a\rb\r\n")},
        {nul_in_value, 400, Get(["x: a", 0, "b\r\n"])},
        {space_before_colon, 400, Get("x : y\r\n")},
        {folded_line, 400, Get("x: y\r\n z\r\n")},
        {no_colon, 400, Get("nonsense\r\n")},
        {empty_name, 400, Get(": y\r\n")},
        {two_spaces, 400, "GET  / HTTP/1.1\r\n" ?HOST "\r\n"},
        {tab_separated, 400, "GET\t/\tHTTP/1.1\r\n" ?HOST "\r\n"},
        {bad_method, 400, "G(T / HTTP/1.1\r\n" ?HOST "\r\n"},
        {bad_target, 400, "GET nothing HTTP/1.1\r\n" ?HOST "\r\n"},
        {fragment, 400, "GET /a#b HTTP/1.1\r\n" ?HOST "\r\n"},
        {star_for_get, 400, "GET * HTTP/1.1\r\n" ?HOST "\r\n"},
        {version_2, 505, "GET / HTTP/2.0\r\n" ?HOST "\r\n"},
        {no_version, 400, "GET /\r\n\r\n"},
        {tunnel, 501, "CONNECT localhost:1 HTTP/1.1\r\n" ?HOST "\r\n"},
        {empty_lines, 400, "\r\n\r\n\r\n\r\n\r\n\r\nGET / HTTP/1.1\r\n" ?HOST "\r\n"},
        {long_target, 414, ["GET /", Long, " HTTP/1.1\r\n" ?HOST "\r\n"]},
        {endless_line, 414, Long},
        {long_field, 431, Get(["x: ", Long, "\r\n"])},
        {many_fields, 431, Get(lists:duplicate(101, "x: y\r\n"))},
        {large_head, 431, Get(lists:duplicate(20, ["x: ", lists:duplicate(4000, $a), "\r\n"]))},
        {expectation, 417, Post("expect: later\r\ncontent-length: 1\r\n")},
        {chunk_size, 400, Chunks("z\r\n")},
        {negative_chunk, 400, Chunks("-1\r\n")},
        {chunk_junk, 400, Chunks("1 x\r\na\r\n0\r\n\r\n")},
        {chunk_overrun, 400, Chunks("1\r\nab\r\n0\r\n\r\n")},
        {chunk_bare_lf, 400, Chunks("1\na\n0\n\n")},
        {long_chunk_line, 400, Chunks(["1;", Long, "\r\na\r\n0\r\n\r\n"])},
        {bad_trailer, 400, Chunks("0\r\nx : y\r\n\r\n")}
    ].

%% Each is answered with its status and the connection closed; the guest, which
%% would answer 200, never sees them.
malformed_requests_are_refused(Config) ->
    with(Config, "p3_http_echo", fun(Port) ->
        Wrong = [
            {Name, Expected, Got}
         || {Name, Expected, Request} <- malformed(),
            Got <- [
                case exchange(Port, Request) of
                    {closed, <<"HTTP/1.1 ", _/binary>> = Reply} -> status(Reply);
                    Other -> Other
                end
            ],
            Got =/= Expected
        ],
        ?assertEqual([], Wrong),
        {closed, Reply} = exchange(Port, closing_get()),
        200 = status(Reply)
    end).

%% What could be read as a second request after a refused one is not.
nothing_follows_a_refusal(Config) ->
    with(Config, "p2_cli_serve_hello_world", fun(Port) ->
        Smuggled = [
            "POST / HTTP/1.1\r\n"
            ?HOST
            "content-length: 4\r\ntransfer-encoding: chunked\r\n\r\n"
            "0\r\n\r\n",
            closing_get()
        ],
        {closed, Reply} = exchange(Port, Smuggled),
        ?assertEqual(1, length(binary:matches(Reply, ~"HTTP/1.1 "))),
        400 = status(Reply)
    end).

%% Bytes past ASCII are allowed in a field value (obs-text) and mean nothing
%% in the fields the listener reads.
bytes_that_are_not_utf8(Config) ->
    with(Config, "p2_cli_serve_hello_world", fun(Port) ->
        Status = fun(Field) ->
            {closed, Reply} = exchange(Port, [
                "GET / HTTP/1.1\r\n" ?HOST, Field, "connection: close\r\n\r\n"
            ]),
            status(Reply)
        end,
        200 = Status(["x: ", 255, 254, "\r\n"]),
        200 = Status(["connection: ", 255, "\r\n"]),
        400 = Status(["transfer-encoding: ", 255, "\r\n"]),
        417 = Status(["expect: ", 255, "\r\n"])
    end).

%% A target that passes the listener and is no URI to Wasmtime.
requests_the_guest_cannot_be_given(Config) ->
    with(Config, "p2_cli_serve_hello_world", fun(Port) ->
        [
            begin
                {closed, Reply} = exchange(Port, [Request, "connection: close\r\n\r\n"]),
                400 = status(Reply)
            end
         || Request <- ["GET /<> HTTP/1.1\r\n" ?HOST, "GET /` HTTP/1.1\r\n" ?HOST]
        ]
    end).

extra_connections_are_503(Config) ->
    with(Config, "p2_cli_serve_hello_world", #{max_connections => 1}, fun(Port) ->
        First = connect(Port),
        ok = gen_tcp:send(First, "GET / HTTP/1.1\r\n" ?HOST "\r\n"),
        200 = status(until(First, ~"Hello, WASI!")),
        {closed, Reply} = read(connect(Port)),
        503 = status(Reply),
        ok = gen_tcp:close(First),
        %% the place is free again once the first is gone
        timer:sleep(100),
        {closed, Next} = exchange(Port, closing_get()),
        200 = status(Next)
    end).

%% A response its reader does not take ends with a reset at the deadline, and
%% the listener keeps serving.
a_slow_reader_is_cut_off(Config) ->
    with(Config, "p3_http_echo", #{request_timeout => 1500}, fun(Port) ->
        Size = 8 * 1024 * 1024,
        {ok, Socket} = gen_tcp:connect({127, 0, 0, 1}, Port, [
            binary, {active, false}, {recbuf, 4096}
        ]),
        ok = gen_tcp:send(Socket, [
            "POST / HTTP/1.1\r\n" ?HOST "content-length: ",
            integer_to_list(Size),
            "\r\n\r\n",
            binary:copy(~"x", Size)
        ]),
        timer:sleep(2500),
        {Ended, Reply} = read(Socket, 2000, <<>>),
        ?assertNotEqual(timeout, Ended),
        ?assert(byte_size(Reply) < Size),
        {closed, Next} = exchange(Port, closing_get()),
        200 = status(Next)
    end).

a_client_that_leaves(Config) ->
    with(Config, "p3_http_echo", fun(Port) ->
        [
            begin
                Socket = connect(Port),
                ok = gen_tcp:send(Socket, Bytes),
                ok = gen_tcp:close(Socket)
            end
         || Bytes <- [
                "GET /",
                "POST / HTTP/1.1\r\n" ?HOST "content-length: 9\r\n\r\nab",
                closing_get()
            ]
        ],
        {closed, Reply} = exchange(Port, closing_get()),
        200 = status(Reply)
    end).

%% ------------------------------------------------------------------- server

stop_closes_everything(Config) ->
    {ok, Listener} = wasmtime_http_listener:start(#{
        component => guest(Config, "p3_cli_serve_sleep")
    }),
    [~"127.0.0.1", Bytes] = binary:split(wasmtime_http_listener:address(Listener), ~":"),
    Port = binary_to_integer(Bytes),
    Idle = connect(Port),
    Busy = connect(Port),
    ok = gen_tcp:send(Busy, closing_get()),
    timer:sleep(200),
    ok = wasmtime_http_listener:stop(Listener),
    [{closed, <<>>} = read(Socket) || Socket <- [Idle, Busy]],
    {error, econnrefused} = gen_tcp:connect({127, 0, 0, 1}, Port, [], 1000),
    ok = wasmtime_http_listener:stop(Listener).

the_listener_ends_with_its_owner(Config) ->
    Test = self(),
    Bin = guest(Config, "p2_cli_serve_hello_world"),
    Owner = spawn(fun() ->
        {ok, Listener} = wasmtime_http_listener:start(#{component => Bin}),
        Test ! {listening, wasmtime_http_listener:address(Listener)},
        receive
            done -> ok
        end
    end),
    receive
        {listening, Address} ->
            [_, Bytes] = binary:split(Address, ~":"),
            Port = binary_to_integer(Bytes),
            gen_tcp:close(connect(Port)),
            Owner ! done,
            timer:sleep(200),
            {error, econnrefused} = gen_tcp:connect({127, 0, 0, 1}, Port, [], 1000)
    after 30000 -> ct:fail(not_listening)
    end.

bad_options_are_refused(Config) ->
    Bin = guest(Config, "p2_cli_serve_hello_world"),
    Start = fun(Options) -> wasmtime_http_listener:start(Options#{component => Bin}) end,
    [
        {error, #{class := link, kind := unsupported_option}} = Start(Options)
     || Options <- [
            #{transport => h2},
            #{nonsense => 1},
            #{serve_opts => #{stdout => capture}}
        ]
    ],
    [
        {error, #{class := link, kind := badarg}} = Start(Options)
     || Options <- [
            #{port => 70000},
            #{ip => localhost},
            #{request_timeout => 0},
            #{max_connections => 0},
            #{scheme => http}
        ]
    ],
    {ok, Core} = file:read_file(code:which(?MODULE)),
    {error, _} = wasmtime_http_listener:start(#{component => Core}),
    {error, #{kind := badarg}} = wasmtime_http_listener:start(#{}),
    {ok, Prepared} = wasmtime_component:prepare(Bin),
    {ok, Listener} = wasmtime_http_listener:start(#{component => Prepared}),
    [_, Port] = binary:split(wasmtime_http_listener:address(Listener), ~":"),
    {error, eaddrinuse} = Start(#{port => binary_to_integer(Port)}),
    ok = wasmtime_http_listener:stop(Listener).

%% A guest's response is checked before a byte of it is written.
what_cannot_be_written(_) ->
    Request = #{method => ~"GET", version => {1, 1}, keep_alive => true},
    Response = fun(Status, Fields) ->
        wasmtime_http1_writer:response(Request, Status, Fields, [])
    end,
    [
        error = Response(Status, Fields)
     || {Status, Fields} <- [
            {101, []},
            {99, []},
            {600, []},
            {200, [{~"x", ~"a\r\nset-cookie: b"}]},
            {200, [{~"x\r\ny", ~"a"}]},
            {200, [{~"content-length", ~"1"}, {~"content-length", ~"1"}]},
            {200, [{~"content-length", ~"-1"}]}
        ]
    ],
    {ok, Head, chunked} = Response(200, [
        {~"connection", ~"upgrade"}, {~"transfer-encoding", ~"gzip"}
    ]),
    Written = iolist_to_binary(Head),
    nomatch = binary:match(Written, [~"upgrade", ~"gzip"]),
    {ok, Empty, discard} = Response(204, [{~"content-length", ~"3"}]),
    nomatch = binary:match(iolist_to_binary(Empty), ~"content-length"),
    error = wasmtime_http1_writer:chunk({length, 1}, ~"ab"),
    error = wasmtime_http1_writer:finish({length, 1}, []),
    {ok, Trailers} = wasmtime_http1_writer:finish(chunked, [
        {~"content-length", ~"1"}, {~"a", ~"b"}
    ]),
    ~"0\r\na: b\r\n\r\n" = iolist_to_binary(Trailers),
    error = wasmtime_http1_writer:finish(chunked, [{~"a", ~"b\r\n"}]).
