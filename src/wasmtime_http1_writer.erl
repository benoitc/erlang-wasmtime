-module(wasmtime_http1_writer).
-moduledoc false.
%% The responses wasmtime_http_listener writes (RFC 9112, with the fields of
%% RFC 9110). A guest's status and fields are checked before a byte goes out,
%% and its body held to what the head said.

-export([response/4, chunk/2, finish/2]).

-export_type([response/0]).

%% what is left to say about one response: how its body is delimited and, for
%% a declared length, the bytes still owed
-type response() :: discard | chunked | close | {length, non_neg_integer()}.

-define(MAX_LENGTH_DIGITS, 19).

%% The head of a response to a request of this method and version, with a
%% guest's status and fields, and how its body is then to be written. `error`
%% for what cannot be sent: an interim or unknown status, a field that is not
%% one, or lengths that do not make one number.
-spec response(
    #{method := binary(), version := {1, 0 | 1}, keep_alive := boolean(), atom() => term()},
    integer(),
    [{binary(), binary()}],
    [{binary(), binary()}]
) -> {ok, iodata(), response()} | error.
response(Request, Status, Fields, Own) when Status >= 200, Status =< 599 ->
    #{method := Method, version := Version, keep_alive := KeepAlive} = Request,
    maybe
        true ?= valid(Fields),
        Named = [{string:lowercase(N), V} || {N, V} <- Fields],
        {ok, Length} ?= declared(wasmtime_http1:values(~"content-length", Named)),
        Kept = [
            F
         || {N, _} = F <- Named,
            not lists:member(N, wasmtime_http1:hop_by_hop()),
            %% a 204 declares no length (RFC 9110 section 8.6)
            N =/= ~"content-length" orelse Status =/= 204
        ],
        Body = Method =/= ~"HEAD" andalso Status =/= 204 andalso Status =/= 304,
        {Framing, Added} = delimit(Body, Length, Version),
        Close = closing(KeepAlive andalso Framing =/= close),
        {ok, head(Status, dated(Kept) ++ Added ++ Own ++ Close), Framing}
    else
        _ -> error
    end;
response(_, _, _, _) ->
    error.

head(Status, Fields) ->
    [
        ~"HTTP/1.1 ",
        integer_to_binary(Status),
        $\s,
        reason(Status),
        ~"\r\n",
        lines(Fields),
        ~"\r\n"
    ].

closing(true) -> [];
closing(false) -> [{~"connection", ~"close"}].

delimit(false, _, _) -> {discard, []};
delimit(true, none, {1, 1}) -> {chunked, [{~"transfer-encoding", ~"chunked"}]};
delimit(true, none, {1, 0}) -> {close, []};
delimit(true, Length, _) -> {{length, Length}, []}.

declared([]) ->
    {ok, none};
declared([Value]) ->
    case wasmtime_http1:digits(Value, ?MAX_LENGTH_DIGITS) of
        {ok, N} -> {ok, N};
        error -> error
    end;
declared(_) ->
    error.

%% Whether every field can be written: a name that is a token and a value
%% with no line break to forge another field with.
valid(Fields) ->
    lists:all(
        fun({N, V}) -> wasmtime_http1:token(N) andalso wasmtime_http1:field_value(V) end, Fields
    ).

lines(Fields) -> [[N, ~": ", V, ~"\r\n"] || {N, V} <- Fields].

%% An origin server with a clock dates its responses (RFC 9110 section 6.6.1).
dated(Fields) ->
    case lists:keymember(~"date", 1, Fields) of
        true -> Fields;
        false -> Fields ++ [{~"date", list_to_binary(httpd_date())}]
    end.

httpd_date() ->
    {{Y, Mo, D}, {H, Mi, S}} = Now = calendar:universal_time(),
    Day = element(
        calendar:day_of_the_week(element(1, Now)),
        {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
    ),
    Month = element(
        Mo,
        {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
    ),
    lists:flatten(
        io_lib:format("~s, ~2..0b ~s ~4..0b ~2..0b:~2..0b:~2..0b GMT", [
            Day, D, Month, Y, H, Mi, S
        ])
    ).

%% Bytes of the body as they go on the wire; `error` past a declared length.
-spec chunk(response(), binary()) -> {ok, iodata(), response()} | error.
chunk(discard, _) ->
    {ok, [], discard};
chunk(Framing, <<>>) ->
    {ok, [], Framing};
chunk(chunked, Bytes) ->
    {ok, [integer_to_binary(byte_size(Bytes), 16), ~"\r\n", Bytes, ~"\r\n"], chunked};
chunk(close, Bytes) ->
    {ok, Bytes, close};
chunk({length, Left}, Bytes) when byte_size(Bytes) =< Left ->
    {ok, Bytes, {length, Left - byte_size(Bytes)}};
chunk({length, _}, _) ->
    error.

%% What ends the body. Trailers are sent after a chunked one only; `error`
%% for a body short of its declared length.
-spec finish(response(), [{binary(), binary()}]) -> {ok, iodata()} | error.
finish(chunked, Trailers) ->
    case valid(Trailers) of
        true ->
            Kept = [
                F
             || {N, _} = F <- Trailers,
                not lists:member(string:lowercase(N), wasmtime_http1:not_trailers())
            ],
            {ok, [~"0\r\n", lines(Kept), ~"\r\n"]};
        false ->
            error
    end;
finish({length, 0}, _) ->
    {ok, []};
finish({length, _}, _) ->
    error;
finish(_, _) ->
    {ok, []}.

reason(200) -> ~"OK";
reason(201) -> ~"Created";
reason(204) -> ~"No Content";
reason(301) -> ~"Moved Permanently";
reason(302) -> ~"Found";
reason(304) -> ~"Not Modified";
reason(400) -> ~"Bad Request";
reason(401) -> ~"Unauthorized";
reason(403) -> ~"Forbidden";
reason(404) -> ~"Not Found";
reason(408) -> ~"Request Timeout";
reason(413) -> ~"Content Too Large";
reason(414) -> ~"URI Too Long";
reason(417) -> ~"Expectation Failed";
reason(431) -> ~"Request Header Fields Too Large";
reason(500) -> ~"Internal Server Error";
reason(501) -> ~"Not Implemented";
reason(503) -> ~"Service Unavailable";
reason(504) -> ~"Gateway Timeout";
reason(505) -> ~"HTTP Version Not Supported";
%% the phrase may be empty (RFC 9112 section 4)
reason(_) -> <<>>.
