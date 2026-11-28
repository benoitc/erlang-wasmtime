-module(wasmtime_http_listener).
-moduledoc """
A live HTTP/1.1 server answering each request with a `wasi:http` handler
component, WASI 0.2 or 0.3: erlang_wasm's `wasi_http_listener`. Each request
gets its own instance.

```erlang
{ok, Bin} = file:read_file("hello.component.wasm"),
{ok, Listener} = wasmtime_http_listener:start(#{component => Bin, port => 8080}),
Address = wasmtime_http_listener:address(Listener),
ok = wasmtime_http_listener:stop(Listener).
```

A 0.3 response is sent as the guest writes it, one part at a time, so a client
that reads slowly makes the guest wait. A 0.2 response is sent once the guest
has written all of it. It speaks cleartext HTTP/1.1 only: put TLS in front of
it. It stops with `stop/1`, or when the process that started it ends.
""".

-export([start/1, stop/1, address/1]).

-export_type([options/0, server/0]).

-type options() :: #{
    component := binary() | wasmtime_component:prepared(),
    ip => inet:ip_address(),
    port => inet:port_number(),
    transport => h1,
    scheme => binary(),
    serve_opts => wasmtime_wasi_preview2:command_options(),
    request_timeout => pos_integer(),
    max_body_bytes => non_neg_integer(),
    max_connections => pos_integer()
}.

-opaque server() :: {wasmtime_http_listener, pid(), binary()}.

%% erlang_wasm's defaults
-define(REQUEST_TIMEOUT, 60000).
-define(MAX_BODY_BYTES, 8 * 1024 * 1024).
%% each connection may hold an instance, which is a thread
-define(MAX_CONNECTIONS, 256).
-define(MAX_REQUESTS_PER_CONNECTION, 100).
%% to write an answer once the request's own time is up
-define(LAST_WORDS, 1000).
%% how long, and how much, is read from a client after its connection is
%% answered with an error, so the answer is not lost to a reset
-define(LINGER_MS, 1000).
-define(LINGER_BYTES, 65536).

-doc """
Start a listener.

- `component`: the handler's bytes, or a component from
  `wasmtime_component:prepare/1`.
- `ip`, `port`: where to listen, `{127, 0, 0, 1}` (this machine only) and any
  free port by default; `{0, 0, 0, 0}` listens on every interface.
- `scheme`: the scheme the guest is told, `~"http"` by default.
- `serve_opts`: the options of `wasmtime_wasi_preview2:run_serve/3` for each
  request: `network`, `env`, `http_transport`, `fuel` and the rest.
- `request_timeout`: the most milliseconds from a request's head to the end of
  its answer, its body and the guest included, 60 seconds by default. It also
  bounds how long a connection may stay idle.
- `max_body_bytes`: the largest request body, 8 MiB by default.
- `max_connections`: connections served at once, 256 by default; one more is
  answered 503.

`transport => h2` is refused: there is no HTTP/2.
""".
-spec start(options()) -> {ok, server()} | {error, term()}.
start(#{component := Component} = Options) ->
    maybe
        {ok, Config} ?= config(Options),
        {ok, Prepared} ?= wasmtime_component:prepare(Component),
        %% refused options, and a component that cannot be instantiated with
        %% them, show here and not as a 500 to every request
        {ok, Version} ?= wasmtime_http_serve:check(Prepared, maps:get(serve_opts, Config)),
        listen(Config#{component => Prepared, streams => Version =:= p3})
    end;
start(_) ->
    refused(badarg, ~"a listener needs a component", #{}).

-doc "The `host:port` the listener is bound to.".
-spec address(server()) -> binary().
address({?MODULE, _, Address}) -> Address.

-doc "Stop a listener: close its socket and its connections.".
-spec stop(server()) -> ok.
stop({?MODULE, Keeper, _}) ->
    Monitor = monitor(process, Keeper),
    Keeper ! {stop, self()},
    receive
        {'DOWN', Monitor, process, Keeper, _} -> ok
    after infinity -> ok
    end.

%% ------------------------------------------------------------------ options

config(Options) ->
    Defaults = #{
        ip => {127, 0, 0, 1},
        port => 0,
        transport => h1,
        scheme => ~"http",
        serve_opts => #{},
        request_timeout => ?REQUEST_TIMEOUT,
        max_body_bytes => ?MAX_BODY_BYTES,
        max_connections => ?MAX_CONNECTIONS
    },
    Config = maps:merge(Defaults, maps:remove(component, Options)),
    Unknown = maps:keys(maps:without(maps:keys(Defaults), Config)),
    Bad = [Key || Key := Value <- Config, is_map_key(Key, Defaults), not option(Key, Value)],
    case {Unknown, Config, Bad} of
        {[_ | _], _, _} ->
            refused(unsupported_option, ~"this runtime does not support the option", #{
                keys => Unknown
            });
        {[], #{transport := h2}, _} ->
            refused(unsupported_option, ~"there is no HTTP/2", #{keys => [transport]});
        {[], _, []} ->
            {ok, Config};
        {[], _, _} ->
            refused(badarg, ~"a listener option is not a value it can take", #{keys => Bad})
    end.

option(ip, IP) -> inet:is_ip_address(IP);
option(port, Port) -> is_integer(Port) andalso Port >= 0 andalso Port =< 65535;
option(transport, Transport) -> Transport =:= h1 orelse Transport =:= h2;
option(scheme, Scheme) -> is_binary(Scheme);
option(serve_opts, Opts) -> is_map(Opts);
option(request_timeout, Ms) -> is_integer(Ms) andalso Ms > 0 andalso Ms =< 16#FFFFFFFF;
option(max_body_bytes, N) -> is_integer(N) andalso N >= 0;
option(max_connections, N) -> is_integer(N) andalso N > 0.

refused(Kind, Message, Ctx) -> wasmtime_error:new(link, Kind, Message, Ctx).

%% ------------------------------------------------------------------ server

%% The keeper owns the socket and watches the caller; the acceptor, linked to
%% it, owns the connections. Killing the acceptor ends every connection, and a
%% connection's end ends its guest.
listen(Config) ->
    Owner = self(),
    Ref = make_ref(),
    {Keeper, Monitor} = spawn_monitor(fun() -> keep(Owner, Ref, Config) end),
    receive
        {Ref, {ok, Address}} ->
            demonitor(Monitor, [flush]),
            {ok, {?MODULE, Keeper, Address}};
        {Ref, {error, Reason}} ->
            demonitor(Monitor, [flush]),
            {error, Reason};
        {'DOWN', Monitor, process, Keeper, Reason} ->
            {error, Reason}
    after infinity -> {error, timeout}
    end.

keep(Owner, Ref, #{ip := IP, port := Port} = Config) ->
    Watched = monitor(process, Owner),
    Family =
        case tuple_size(IP) of
            4 -> inet;
            8 -> inet6
        end,
    Options = [
        binary,
        Family,
        {ip, IP},
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 128},
        {send_timeout_close, true}
    ],
    case gen_tcp:listen(Port, Options) of
        {ok, Socket} ->
            {ok, Bound} = inet:port(Socket),
            Address = iolist_to_binary([bracketed(IP), $:, integer_to_binary(Bound)]),
            process_flag(trap_exit, true),
            Acceptor = spawn_link(fun() ->
                %% a connection that crashes must not end the others
                process_flag(trap_exit, true),
                accept(Socket, Config#{address => Address}, #{})
            end),
            Owner ! {Ref, {ok, Address}},
            kept(Watched, Acceptor, Socket);
        {error, Reason} ->
            Owner ! {Ref, {error, Reason}}
    end.

kept(Watched, Acceptor, Socket) ->
    receive
        {stop, _} -> ok;
        {'DOWN', Watched, process, _, _} -> ok;
        {'EXIT', Acceptor, _} -> ok
    after infinity -> ok
    end,
    exit(Acceptor, kill),
    receive
        {'EXIT', Acceptor, _} -> ok
    after ?LINGER_MS -> ok
    end,
    gen_tcp:close(Socket).

%% The address as a URL authority writes it: an IPv6 one in brackets.
bracketed({_, _, _, _} = IP) -> inet:ntoa(IP);
bracketed(IP) -> [$[, inet:ntoa(IP), $]].

accept(Listener, #{max_connections := Max} = Config, Connections) ->
    case gen_tcp:accept(Listener) of
        {ok, Socket} ->
            Live = ended(Connections),
            case map_size(Live) < Max of
                true ->
                    Pid = spawn_link(fun() -> connection(Config) end),
                    %% a client already gone: the process gives up waiting
                    _ =
                        gen_tcp:controlling_process(Socket, Pid) =:= ok andalso
                            (Pid ! {socket, Socket}),
                    accept(Listener, Config, Live#{Pid => true});
                false ->
                    busy(Socket),
                    accept(Listener, Config, Live)
            end;
        %% the keeper is gone: end the connections with it
        {error, closed} ->
            exit(shutdown);
        %% out of file descriptors, or a connection gone before it was taken
        {error, _} ->
            timer:sleep(100),
            accept(Listener, Config, ended(Connections))
    end.

ended(Connections) ->
    receive
        {'EXIT', Pid, _} when is_map_key(Pid, Connections) ->
            ended(maps:remove(Pid, Connections))
    after 0 -> Connections
    end.

busy(Socket) ->
    _ = inet:setopts(Socket, [{send_timeout, 100}]),
    _ = gen_tcp:send(
        Socket,
        ~"HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
    ),
    gen_tcp:close(Socket).

%% -------------------------------------------------------------- connection

connection(Config) ->
    receive
        {socket, Socket} -> requests(wasmtime_http1:reader(Socket), Socket, Config, 1)
    after ?LINGER_MS -> ok
    end.

requests(Reader, Socket, #{request_timeout := Timeout} = Config, Count) ->
    case wasmtime_http1:read_head(Reader, now_ms() + Timeout) of
        {ok, Head, Rest} ->
            %% the request's time starts with its head
            Deadline = now_ms() + Timeout,
            Kept = Head#{
                keep_alive := maps:get(keep_alive, Head) andalso
                    Count < ?MAX_REQUESTS_PER_CONNECTION
            },
            case request(Rest, Socket, Config, Kept, Deadline) of
                {again, Next} -> requests(Next, Socket, Config, Count + 1);
                close -> gen_tcp:close(Socket)
            end;
        {refused, Status} ->
            refuse(Socket, Status);
        _ ->
            gen_tcp:close(Socket)
    end.

%% {again, Reader} to read the next request, or close
request(Reader, Socket, #{max_body_bytes := Max} = Config, Head, Deadline) ->
    #{framing := Framing, expect_continue := Expect} = Head,
    TooLarge =
        case Framing of
            {length, N} -> N > Max;
            _ -> false
        end,
    _ =
        Expect andalso not TooLarge andalso Framing =/= none andalso
            send(Socket, ~"HTTP/1.1 100 Continue\r\n\r\n", Deadline),
    case wasmtime_http1:read_body(Reader, Framing, Max, Deadline) of
        {ok, Body, Trailers, Rest} ->
            case
                answer(Socket, Config, Head, guest_request(Config, Head, Body, Trailers), Deadline)
            of
                keep -> {again, Rest};
                close -> close
            end;
        {refused, Status} ->
            ok = refuse(Socket, Status),
            close;
        closed ->
            close
    end.

guest_request(#{scheme := Scheme, address := Address}, Head, Body, Trailers) ->
    #{method := Method, path := Path, authority := Authority, headers := Headers} = Head,
    #{
        method => Method,
        path => Path,
        scheme => Scheme,
        authority =>
            case Authority of
                <<>> -> Address;
                _ -> Authority
            end,
        headers => Headers,
        body => Body,
        trailers => Trailers
    }.

%% A request that is not taken: answered, and the connection closed with what
%% the client is still sending read away.
refuse(Socket, Status) ->
    Request = #{method => ~"GET", version => {1, 1}, keep_alive => false},
    case own_answer(Socket, Request, Status, now_ms() + ?LAST_WORDS) of
        ok -> linger(Socket);
        {error, _} -> gen_tcp:close(Socket)
    end.

%% An answer of the listener's own.
own_answer(Socket, Request, Status, Deadline) ->
    Body = explanation(Status),
    Length = [{~"content-length", integer_to_binary(byte_size(Body))}],
    {ok, Head, Framing} = wasmtime_http1_writer:response(Request, Status, Length, []),
    {ok, Data, _} = wasmtime_http1_writer:chunk(Framing, Body),
    send(Socket, [Head, Data], Deadline).

%% erlang_wasm's words; a request that could not be read gets none.
explanation(408) -> ~"request body timed out";
explanation(413) -> ~"request body too large";
explanation(500) -> ~"wasi:http reactor error";
explanation(504) -> ~"wasi:http reactor timed out";
explanation(_) -> <<>>.

linger(Socket) ->
    _ = gen_tcp:shutdown(Socket, write),
    drain(Socket, now_ms() + ?LINGER_MS, ?LINGER_BYTES),
    gen_tcp:close(Socket).

drain(Socket, Deadline, Left) when Left > 0 ->
    case gen_tcp:recv(Socket, 0, max(0, Deadline - now_ms())) of
        {ok, Data} -> drain(Socket, Deadline, Left - byte_size(Data));
        {error, _} -> ok
    end;
drain(_, _, _) ->
    ok.

send(Socket, Data, Deadline) ->
    case inet:setopts(Socket, [{send_timeout, max(1, Deadline - now_ms())}]) of
        ok -> gen_tcp:send(Socket, Data);
        {error, _} = Error -> Error
    end.

now_ms() -> erlang:monotonic_time(millisecond).

%% ------------------------------------------------------------------- guest

%% The guest runs in a linked process, which this one can stop at the
%% deadline. A 0.3 response comes in parts, each written before the guest goes
%% on; `Sent` is `none` until the head is out, then how the body is delimited,
%% and `done` once it has ended. After the head, a failure can only cut the
%% connection, so the client does not take what it got for the whole answer.
answer(Socket, Config, Head, Request, Deadline) ->
    #{component := Component, serve_opts := Options, streams := Streams} = Config,
    Connection = self(),
    Work = fun() ->
        Connection ! {served, self(), serve(Streams, Component, Request, Options, Connection)}
    end,
    {Guest, Monitor} = spawn_opt(Work, [link, monitor]),
    wait(
        #{socket => Socket, head => Head, guest => Guest, monitor => Monitor, until => Deadline},
        none
    ).

serve(true, Component, Request, Options, Connection) ->
    Emit = fun(Part) ->
        Connection ! {part, self(), Part},
        receive
            {taken, Connection} -> ok
        after infinity -> ok
        end
    end,
    guarded(fun() -> wasmtime_http_serve:stream(Component, Request, Options, Emit) end);
serve(false, Component, Request, Options, _) ->
    guarded(fun() -> wasmtime_http_serve:run(Component, Request, Options) end).

%% The process is linked to its connection: it must end normally.
guarded(Serve) ->
    try
        Serve()
    catch
        Class:Reason:Stack -> {error, {Class, Reason, Stack}}
    end.

wait(#{guest := Guest, monitor := Monitor, until := Deadline} = State, Sent) ->
    receive
        {part, Guest, Part} ->
            case write(State, Sent, Part) of
                {ok, Next} ->
                    Guest ! {taken, self()},
                    wait(State, Next);
                failed ->
                    stop_guest(State),
                    cut(State, Sent)
            end;
        {served, Guest, Result} ->
            demonitor(Monitor, [flush]),
            served(State, Sent, Result);
        {'DOWN', Monitor, process, Guest, Reason} ->
            served(State, Sent, {error, Reason})
    after max(0, Deadline - now_ms()) ->
        stop_guest(State),
        late(State, Sent)
    end.

stop_guest(#{guest := Guest, monitor := Monitor}) ->
    demonitor(Monitor, [flush]),
    unlink(Guest),
    exit(Guest, kill),
    ok.

write(#{head := Head} = State, none, {head, Status, Headers}) ->
    case wasmtime_http1_writer:response(Head, Status, Headers, []) of
        {ok, Bytes, Framing} -> written(State, Bytes, Framing);
        error -> failed
    end;
write(State, Framing, {chunk, Chunk}) when Framing =/= none, Framing =/= done ->
    case wasmtime_http1_writer:chunk(Framing, Chunk) of
        {ok, Bytes, Next} -> written(State, Bytes, Next);
        error -> failed
    end;
write(State, Framing, {done, Trailers}) when Framing =/= none, Framing =/= done ->
    case wasmtime_http1_writer:finish(Framing, Trailers) of
        %% a body that only the connection's end delimits is not to be kept
        {ok, Bytes} when Framing =:= close -> written(State, Bytes, ended);
        {ok, Bytes} -> written(State, Bytes, done);
        error -> failed
    end.

written(#{socket := Socket, until := Deadline}, Bytes, Next) ->
    case send(Socket, Bytes, Deadline) of
        ok -> {ok, Next};
        {error, _} -> failed
    end.

%% The guest has ended.
served(State, done, _) ->
    next(State);
served(_, ended, _) ->
    close;
served(State, none, {ok, Status, Headers, Body}) ->
    whole(State, Status, Headers, Body);
%% the request passed the listener and is none to Wasmtime: nothing ran
served(State, none, {error, #{class := link, kind := badarg}}) ->
    status(State, 400);
served(State, none, Result) ->
    logger:warning("wasi:http handler failed: ~0P", [Result, 20]),
    status(State, 500);
served(State, Sent, Result) ->
    logger:warning("wasi:http handler failed mid-response: ~0P", [Result, 20]),
    cut(State, Sent).

late(State, done) -> next(State);
late(_, ended) -> close;
late(State, none) -> status(State, 504);
late(State, Sent) -> cut(State, Sent).

%% A 0.2 response, all of it at hand: it gets a length unless the guest gave
%% one, which then has to be right.
whole(#{head := Head} = State, Status, Headers, Body) ->
    Declared = lists:any(
        fun({Name, _}) -> string:lowercase(Name) =:= ~"content-length" end, Headers
    ),
    Own =
        case Declared orelse maps:get(method, Head) =:= ~"HEAD" of
            true -> [];
            false when Status =:= 204; Status =:= 304 -> [];
            false -> [{~"content-length", integer_to_binary(byte_size(Body))}]
        end,
    maybe
        {ok, Bytes, Framing} ?= wasmtime_http1_writer:response(Head, Status, Headers ++ Own, []),
        {ok, Data, Rest} ?= wasmtime_http1_writer:chunk(Framing, Body),
        {ok, End} ?= wasmtime_http1_writer:finish(Rest, []),
        {ok, _} ?= written(State, [Bytes, Data, End], done),
        next(State)
    else
        failed ->
            close;
        error ->
            logger:warning("wasi:http handler made a response that cannot be sent"),
            status(State, 500)
    end.

%% The listener's own answer, in place of the guest's.
status(#{socket := Socket, head := Head, until := Deadline} = State, Status) ->
    case own_answer(Socket, Head, Status, max(Deadline, now_ms() + ?LAST_WORDS)) of
        ok -> next(State);
        {error, _} -> close
    end.

next(#{head := #{keep_alive := true}}) -> keep;
next(_) -> close.

%% Abort: a reset cannot be mistaken for the end of a body.
cut(State, none) ->
    status(State, 500);
cut(#{socket := Socket}, _) ->
    _ = inet:setopts(Socket, [{linger, {true, 0}}]),
    close.
