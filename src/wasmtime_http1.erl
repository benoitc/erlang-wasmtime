-module(wasmtime_http1).
-moduledoc false.
%% HTTP/1.1 as wasmtime_http_listener reads and writes it: RFC 9112, with the
%% fields of RFC 9110. The reader is strict, since the peer is not trusted:
%% what two parsers could read differently is refused, never repaired. Every
%% line, head and body has a bound and every read a deadline.

-export([reader/1, read_head/2, read_body/4]).
%% the grammar wasmtime_http1_writer checks what it writes against
-export([token/1, field_value/1, digits/2, values/2, not_trailers/0, hop_by_hop/0]).

-export_type([reader/0, head/0, framing/0]).

-opaque reader() :: {gen_tcp:socket(), binary()}.

-type head() :: #{
    method := binary(),
    path := binary(),
    %% from an absolute-form target, else `Host`; may be empty
    authority := binary(),
    version := {1, 0 | 1},
    headers := [{binary(), binary()}],
    framing := framing(),
    keep_alive := boolean(),
    expect_continue := boolean()
}.

-type framing() :: none | {length, non_neg_integer()} | chunked.

%% RFC 9112 section 3: at least 8000 octets of request line are to be taken
-define(MAX_REQUEST_LINE, 8192).
-define(MAX_FIELD_LINE, 8192).
-define(MAX_HEAD, 65536).
-define(MAX_FIELDS, 100).
%% section 2.2: empty lines before a request line are skipped, a few of them
-define(MAX_EMPTY_LINES, 4).
-define(MAX_CHUNK_LINE, 4096).
%% 2^64 has 16 hex digits and 20 decimal ones
-define(MAX_CHUNK_DIGITS, 16).
-define(MAX_LENGTH_DIGITS, 19).

%% never forwarded from a response's fields: they frame the connection, which
%% is the listener's business (RFC 9110 sections 7.6.1 and 6.5.1)
-define(HOP_BY_HOP, [
    ~"connection",
    ~"keep-alive",
    ~"proxy-connection",
    ~"transfer-encoding",
    ~"upgrade",
    ~"te",
    ~"trailer"
]).
%% nor allowed as trailers (RFC 9110 section 6.5.1)
-define(NOT_TRAILERS, [~"content-length", ~"host", ~"content-type", ~"authorization" | ?HOP_BY_HOP]).

%% never forwarded from a response's fields: they frame the connection, which
%% is the listener's business
-spec hop_by_hop() -> [binary()].
hop_by_hop() -> ?HOP_BY_HOP.

-spec not_trailers() -> [binary()].
not_trailers() -> ?NOT_TRAILERS.

-spec reader(gen_tcp:socket()) -> reader().
reader(Socket) -> {Socket, <<>>}.

%% --------------------------------------------------------------------- head

%% `idle` is a connection that ended, or ran out of time, before sending a
%% byte of a request; `{refused, Status}` a request to answer and close on.
-spec read_head(reader(), integer()) ->
    {ok, head(), reader()} | {refused, 100..599} | idle | closed.
read_head(Reader, Deadline) ->
    case request_line(Reader, Deadline, 0) of
        {ok, Line, Rest} ->
            maybe
                {ok, Method, Target, Version} ?= parse_request_line(Line),
                {ok, Fields, After} ?= read_fields(Rest, Deadline, ?MAX_HEAD),
                {ok, Head} ?= head(Method, Target, Version, Fields),
                {ok, Head, After}
            else
                {error, {status, Status}} -> {refused, Status};
                {error, timeout} -> {refused, 408};
                {error, too_long} -> {refused, 431};
                {error, bad_line} -> {refused, 400};
                {error, closed} -> closed
            end;
        {error, too_long} ->
            {refused, 414};
        {error, bad_line} ->
            {refused, 400};
        {error, timeout, <<>>} ->
            idle;
        {error, timeout, _} ->
            {refused, 408};
        {error, closed, <<>>} ->
            idle;
        {error, closed, _} ->
            closed
    end.

request_line(Reader, Deadline, Empty) ->
    case line(Reader, ?MAX_REQUEST_LINE, Deadline) of
        {ok, <<>>, Rest} when Empty < ?MAX_EMPTY_LINES ->
            request_line(Rest, Deadline, Empty + 1);
        {ok, <<>>, _} ->
            {error, bad_line};
        {ok, Line, Rest} ->
            {ok, Line, Rest};
        {error, Reason, Partial} when Reason =:= timeout; Reason =:= closed ->
            {error, Reason, Partial};
        {error, Reason, _} ->
            {error, Reason}
    end.

%% method SP request-target SP HTTP-version, with single spaces (section 3)
parse_request_line(Line) ->
    case binary:split(Line, ~" ", [global]) of
        [Method, Target, Version] ->
            case token(Method) andalso visible(Target) of
                true -> version(Method, Target, Version);
                false -> refuse(400)
            end;
        _ ->
            refuse(400)
    end.

version(Method, Target, ~"HTTP/1.1") ->
    {ok, Method, Target, {1, 1}};
version(Method, Target, ~"HTTP/1.0") ->
    {ok, Method, Target, {1, 0}};
version(_, _, <<"HTTP/", Major, $., Minor>>) when
    Major >= $0, Major =< $9, Minor >= $0, Minor =< $9
->
    refuse(505);
version(_, _, _) ->
    refuse(400).

refuse(Status) -> {error, {status, Status}}.

head(Method, Target, Version, Fields) ->
    maybe
        {ok, Named, Path} ?= target(Method, Target),
        {ok, Host} ?= host(Version, values(~"host", Fields)),
        {ok, Framing} ?= framing(Version, Fields),
        {ok, Expect} ?= expect(Version, values(~"expect", Fields)),
        Authority =
            case Named of
                none -> Host;
                _ -> Named
            end,
        {ok, #{
            method => Method,
            path => Path,
            authority => Authority,
            version => Version,
            headers => Fields,
            framing => Framing,
            keep_alive => keep_alive(Version, Fields),
            expect_continue => Expect
        }}
    end.

%% The target forms of section 3.2. `CONNECT` asks for a tunnel, which this
%% is not: refused, and the connection closed (RFC 9931 section 8).
target(~"CONNECT", _) ->
    refuse(501);
target(Method, Target) ->
    case binary:match(Target, ~"#") of
        nomatch -> form(Method, Target);
        _ -> refuse(400)
    end.

form(_, <<"/", _/binary>> = Path) ->
    {ok, none, Path};
form(~"OPTIONS", ~"*") ->
    {ok, none, ~"*"};
form(_, Target) ->
    case binary:split(Target, ~"://") of
        [Scheme, Rest] ->
            case lists:member(string:lowercase(Scheme), [~"http", ~"https"]) of
                true -> absolute(Rest);
                false -> refuse(400)
            end;
        _ ->
            refuse(400)
    end.

absolute(Rest) ->
    {Authority, Path} =
        case binary:match(Rest, [~"/", ~"?"]) of
            nomatch ->
                {Rest, ~"/"};
            {At, _} ->
                <<A:At/binary, Tail/binary>> = Rest,
                case Tail of
                    <<"/", _/binary>> -> {A, Tail};
                    _ -> {A, <<"/", Tail/binary>>}
                end
        end,
    case authority(Authority) of
        true -> {ok, Authority, Path};
        false -> refuse(400)
    end.

%% Exactly one `Host` in HTTP/1.1, never two (section 3.2).
host({1, 1}, []) ->
    refuse(400);
host(_, []) ->
    {ok, <<>>};
host(_, [Host]) ->
    case Host =:= <<>> orelse authority(Host) of
        true -> {ok, Host};
        false -> refuse(400)
    end;
host(_, _) ->
    refuse(400).

%% uri-host [ ":" port ], without userinfo (RFC 9110 section 7.2)
authority(Bytes) ->
    case
        re:run(Bytes, ~B"^(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._~%!$&'()*+,;=-]+)(?::([0-9]{1,5}))?$", [
            {capture, all_but_first, binary}
        ])
    of
        {match, []} -> true;
        {match, [Port]} -> binary_to_integer(Port) =< 65535;
        nomatch -> false
    end.

%% Section 6: one way to find where a body ends, or none of it is read.
framing(Version, Fields) ->
    case {values(~"transfer-encoding", Fields), values(~"content-length", Fields)} of
        {[], []} ->
            {ok, none};
        {[], [Length]} ->
            case digits(Length, ?MAX_LENGTH_DIGITS) of
                {ok, 0} -> {ok, none};
                {ok, N} -> {ok, {length, N}};
                error -> refuse(400)
            end;
        {[_ | _] = Codings, []} when Version =:= {1, 1} ->
            coding(tokens(Codings));
        %% both, a repeated length, or a coding in HTTP/1.0 (section 6.1)
        _ ->
            refuse(400)
    end.

%% Only `chunked` is decoded; it has to be the last coding.
coding([~"chunked"]) ->
    {ok, chunked};
coding(Codings) ->
    case Codings =/= [] andalso lists:last(Codings) =:= ~"chunked" of
        true ->
            case lists:member(~"chunked", lists:droplast(Codings)) of
                true -> refuse(400);
                false -> refuse(501)
            end;
        false ->
            refuse(400)
    end.

%% RFC 9110 section 10.1.1; HTTP/1.0 has no expectations.
expect({1, 0}, _) ->
    {ok, false};
expect(_, []) ->
    {ok, false};
expect(_, Values) ->
    case tokens(Values) of
        [~"100-continue"] -> {ok, true};
        _ -> refuse(417)
    end.

%% An HTTP/1.0 connection is closed after its response.
keep_alive({1, 0}, _) ->
    false;
keep_alive(_, Fields) ->
    not lists:member(~"close", tokens(values(~"connection", Fields))).

-spec values(binary(), [{binary(), binary()}]) -> [binary()].
values(Name, Fields) -> [V || {N, V} <- Fields, N =:= Name].

%% the members of a comma-separated field, lowercased
tokens(Values) ->
    [
        lower(Token)
     || Value <- Values,
        Part <- binary:split(Value, ~",", [global]),
        Token <- [trim(Part)],
        Token =/= <<>>
    ].

%% ASCII only: a value may hold bytes that are no UTF-8
lower(Bytes) ->
    <<<<(lower_byte(C))>> || <<C>> <= Bytes>>.

lower_byte(C) when C >= $A, C =< $Z -> C + 32;
lower_byte(C) -> C.

-spec digits(binary(), pos_integer()) -> {ok, non_neg_integer()} | error.
digits(Bytes, Max) when byte_size(Bytes) >= 1, byte_size(Bytes) =< Max ->
    case lists:all(fun(C) -> C >= $0 andalso C =< $9 end, binary_to_list(Bytes)) of
        true -> {ok, binary_to_integer(Bytes)};
        false -> error
    end;
digits(_, _) ->
    error.

%% ------------------------------------------------------------------- fields

%% Field lines up to the empty one, names lowercased: of a head or of a
%% trailer section, within Left bytes.
read_fields(Reader, Deadline, Left) ->
    read_fields(Reader, Deadline, Left, 0, []).

read_fields(Reader, Deadline, Left, Count, Acc) ->
    case line(Reader, min(Left, ?MAX_FIELD_LINE), Deadline) of
        {ok, <<>>, Rest} ->
            {ok, lists:reverse(Acc), Rest};
        {ok, _, _} when Count >= ?MAX_FIELDS ->
            {error, too_long};
        {ok, Line, Rest} ->
            maybe
                {ok, Field} ?= field(Line),
                Remaining = Left - byte_size(Line) - 2,
                read_fields(Rest, Deadline, max(Remaining, 0), Count + 1, [Field | Acc])
            end;
        {error, Reason, _} ->
            {error, Reason}
    end.

%% field-name ":" OWS field-value OWS (section 5). A line starting with
%% whitespace is obsolete line folding, and whitespace before the colon is
%% how requests are smuggled: both fail the name's check.
field(Line) ->
    case binary:split(Line, ~":") of
        [Name, Raw] ->
            Value = trim(Raw),
            case token(Name) andalso field_value(Value) of
                true -> {ok, {string:lowercase(Name), Value}};
                false -> refuse(400)
            end;
        _ ->
            refuse(400)
    end.

trim(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t -> trim(Rest);
trim(Bytes) -> trim_end(Bytes).

trim_end(<<>>) ->
    <<>>;
trim_end(Bytes) ->
    case binary:last(Bytes) of
        C when C =:= $\s; C =:= $\t -> trim_end(binary:part(Bytes, 0, byte_size(Bytes) - 1));
        _ -> Bytes
    end.

-spec token(binary()) -> boolean().
token(<<>>) -> false;
token(Bytes) -> lists:all(fun tchar/1, binary_to_list(Bytes)).

tchar(C) -> alnum(C) orelse lists:member(C, "!#$%&'*+-.^_`|~").

alnum(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
        (C >= $0 andalso C =< $9).

visible(<<>>) -> false;
visible(Bytes) -> lists:all(fun(C) -> C > 32 andalso C < 127 end, binary_to_list(Bytes)).

%% visible characters, obs-text, spaces and tabs: no CR, LF, NUL or other
%% control
-spec field_value(binary()) -> boolean().
field_value(Bytes) ->
    lists:all(
        fun(C) -> C =:= $\t orelse (C >= 32 andalso C =/= 127) end,
        binary_to_list(Bytes)
    ).

%% --------------------------------------------------------------------- body

%% The whole body, of at most Max bytes, and the trailers of a chunked one.
-spec read_body(reader(), framing(), non_neg_integer(), integer()) ->
    {ok, binary(), [{binary(), binary()}], reader()} | {refused, 100..599} | closed.
read_body(Reader, none, _, _) ->
    {ok, <<>>, [], Reader};
read_body(_, {length, Length}, Max, _) when Length > Max ->
    {refused, 413};
read_body(Reader, {length, Length}, _, Deadline) ->
    case exactly(Reader, Length, Deadline) of
        {ok, Body, Rest} -> {ok, Body, [], Rest};
        {error, Reason} -> body_error(Reason)
    end;
read_body(Reader, chunked, Max, Deadline) ->
    chunks(Reader, Max, Deadline, <<>>).

body_error(timeout) -> {refused, 408};
body_error(too_long) -> {refused, 431};
body_error(bad_line) -> {refused, 400};
body_error({status, Status}) -> {refused, Status};
body_error(closed) -> closed.

%% Section 7.1.
chunks(Reader, Max, Deadline, Body) ->
    case line(Reader, ?MAX_CHUNK_LINE, Deadline) of
        {ok, Line, Rest} ->
            case chunk_size(Line) of
                {ok, 0} ->
                    trailers(Rest, Deadline, Body);
                {ok, Size} when byte_size(Body) + Size > Max ->
                    {refused, 413};
                {ok, Size} ->
                    chunk_data(Rest, Size, Max, Deadline, Body);
                error ->
                    {refused, 400}
            end;
        {error, too_long, _} ->
            {refused, 400};
        {error, Reason, _} ->
            body_error(Reason)
    end.

chunk_data(Reader, Size, Max, Deadline, Body) ->
    case exactly(Reader, Size + 2, Deadline) of
        {ok, <<Data:Size/binary, "\r\n">>, Rest} ->
            chunks(Rest, Max, Deadline, <<Body/binary, Data/binary>>);
        {ok, _, _} ->
            {refused, 400};
        {error, Reason} ->
            body_error(Reason)
    end.

trailers(Reader, Deadline, Body) ->
    case read_fields(Reader, Deadline, ?MAX_HEAD) of
        {ok, Fields, Rest} ->
            Kept = [F || {N, _} = F <- Fields, not lists:member(N, ?NOT_TRAILERS)],
            {ok, Body, Kept, Rest};
        {error, Reason} ->
            body_error(Reason)
    end.

%% chunk-size, then nothing or extensions, which are ignored
chunk_size(Line) ->
    case
        re:run(Line, ~"^([0-9A-Fa-f]+)(?:[ \t]*;[^\\x00-\\x08\\x0a-\\x1f\\x7f]*)?$", [
            {capture, [1], binary}
        ])
    of
        {match, [Hex]} when byte_size(Hex) =< ?MAX_CHUNK_DIGITS ->
            {ok, binary_to_integer(Hex, 16)};
        _ ->
            error
    end.

%% ------------------------------------------------------------------ reading

%% One line without its CRLF. A bare LF or a CR elsewhere is refused (section
%% 2.2), as is a line past Max. An error carries what had arrived.
line({Socket, Buffer}, Max, Deadline) ->
    case binary:match(Buffer, ~"\n") of
        {At, 1} when At >= 1, At =< Max + 1 ->
            <<Line:At/binary, "\n", Rest/binary>> = Buffer,
            Content = binary:part(Line, 0, At - 1),
            case binary:last(Line) =:= $\r andalso binary:match(Content, ~"\r") =:= nomatch of
                true -> {ok, Content, {Socket, Rest}};
                false -> {error, bad_line, Buffer}
            end;
        {0, 1} ->
            {error, bad_line, Buffer};
        {_, 1} ->
            {error, too_long, Buffer};
        nomatch when byte_size(Buffer) > Max + 1 ->
            {error, too_long, Buffer};
        nomatch ->
            case receive_more(Socket, Deadline) of
                {ok, Data} -> line({Socket, <<Buffer/binary, Data/binary>>}, Max, Deadline);
                {error, Reason} -> {error, Reason, Buffer}
            end
    end.

exactly({Socket, Buffer}, Length, _) when byte_size(Buffer) >= Length ->
    <<Bytes:Length/binary, Rest/binary>> = Buffer,
    {ok, Bytes, {Socket, Rest}};
exactly({Socket, Buffer}, Length, Deadline) ->
    case receive_more(Socket, Deadline) of
        {ok, Data} -> exactly({Socket, <<Buffer/binary, Data/binary>>}, Length, Deadline);
        {error, Reason} -> {error, Reason}
    end.

receive_more(Socket, Deadline) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left =< 0 ->
            {error, timeout};
        Left ->
            case gen_tcp:recv(Socket, 0, Left) of
                {ok, Data} -> {ok, Data};
                {error, timeout} -> {error, timeout};
                {error, _} -> {error, closed}
            end
    end.
