-module(wasmtime_http_transport).
-moduledoc """
Your own sender for a component's outgoing `wasi:http` requests: erlang_wasm's
`wasi_http_transport`.

Name a module with this behaviour as `http_transport`, beside the `http` or
`network` grant. For each request the guest sends, `request/2` runs in the
process serving the instance's host calls, and the guest waits for its answer.
The address was checked against the grant: connect to `address`, and keep
`host` for the `Host` header and TLS.
""".

-export([deadline/1, within/2, tls_opts/2, over_limit/2]).
%% for the runtime
-export([settings/3, perform/2]).

-export_type([request/0, response/0, settings/0]).

-type request() :: #{
    host := binary(),
    port := inet:port_number(),
    address := inet:ip_address(),
    scheme := binary(),
    method := binary(),
    path := binary(),
    headers := [{binary(), binary()}],
    body := binary(),
    tls := [term()],
    connect_timeout := non_neg_integer() | undefined,
    first_byte_timeout := non_neg_integer() | undefined,
    between_bytes_timeout := non_neg_integer() | undefined,
    max_body_bytes := pos_integer()
}.
-type response() ::
    {ok, 0..65535, [{binary(), binary()}], iodata()}
    | {error, {binary(), term()}}.
-opaque settings() :: {module(), list(), pos_integer()}.

%% the overall deadline of one request, as erlang_wasm's
-define(TIMEOUT, 30000).

-doc """
Send the request and answer with the whole response, or with a `wasi:http`
error code by its WIT name, such as `{error, {~"connection-refused", none}}`.
`Timeout` is the deadline of the whole exchange.
""".
-callback request(request(), timeout()) -> response().

-doc "The monotonic millisecond at which `Timeout` from now runs out.".
-spec deadline(timeout()) -> integer() | infinity.
deadline(infinity) -> infinity;
deadline(Timeout) -> erlang:monotonic_time(millisecond) + Timeout.

-doc """
How long one wait may last: `Wait` (a step's own timeout, or `undefined` for
none), never past `Deadline`. Zero once the deadline has passed.
""".
-spec within(timeout() | undefined, integer() | infinity) -> timeout().
within(undefined, infinity) ->
    infinity;
within(Wait, infinity) ->
    Wait;
within(Wait, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    case Wait of
        undefined -> Left;
        infinity -> Left;
        _ -> min(Wait, Left)
    end.

-doc "Whether a body of `Size` bytes is over the request's `max_body_bytes`.".
-spec over_limit(non_neg_integer(), request()) -> boolean().
over_limit(Size, Request) ->
    Size > maps:get(max_body_bytes, Request, infinity).

-doc """
The TLS options for a request to `Host`, naming it as the server. A transport
connects to `address`, which loses the name the certificate is checked
against, so it is given to TLS, unless the options carry one or `Host` is an
address.
""".
-spec tls_opts(binary(), list()) -> list().
tls_opts(Host, Tls) ->
    Name = binary_to_list(Host),
    case inet:parse_address(Name) of
        {ok, _} ->
            Tls;
        {error, _} ->
            case lists:keymember(server_name_indication, 1, Tls) of
                true -> Tls;
                false -> [{server_name_indication, Name} | Tls]
            end
    end.

-doc false.
-spec settings(module(), list(), pos_integer()) -> settings().
settings(Module, Tls, MaxBody) when is_atom(Module), is_list(Tls) ->
    {Module, Tls, MaxBody};
settings(Module, Tls, _) ->
    erlang:error({bad_http_transport, Module, Tls}).

%% Run the transport for a request as the NIF sends it: its answer in the
%% NIF's form, or what to say about a transport that failed.
-doc false.
-spec perform(settings(), tuple()) ->
    {answer, tuple()} | {crashed, #{atom() => term()}}.
perform({Module, Tls, MaxBody}, Wire) ->
    try Module:request(request_map(Wire, Tls, MaxBody), ?TIMEOUT) of
        Response ->
            case answer(Response) of
                {ok, Answer} -> {answer, Answer};
                error -> {crashed, #{reason => {bad_return, Response}}}
            end
    catch
        Class:Reason:Stack ->
            {crashed, #{reason => Reason, class => Class, stacktrace => Stack}}
    end.

request_map(
    {Method, Scheme, Host, Address, Port, Path, Headers, Body, Connect, First, Between},
    Tls,
    MaxBody
) ->
    {ok, Ip} = inet:parse_address(binary_to_list(Address)),
    #{
        method => Method,
        scheme => Scheme,
        host => Host,
        address => Ip,
        port => Port,
        path => Path,
        headers => Headers,
        body => Body,
        tls => Tls,
        connect_timeout => Connect,
        first_byte_timeout => First,
        between_bytes_timeout => Between,
        max_body_bytes => MaxBody
    }.

answer({ok, Status, Headers, Body}) when
    is_integer(Status), Status >= 0, Status =< 65535, is_list(Headers)
->
    Pairs = lists:all(
        fun
            ({Name, Value}) -> is_binary(Name) andalso is_binary(Value);
            (_) -> false
        end,
        Headers
    ),
    try Pairs andalso {ok, {ok, Status, Headers, iolist_to_binary(Body)}} of
        false -> error;
        Answer -> Answer
    catch
        error:badarg -> error
    end;
answer({error, {Code, Payload}}) when is_binary(Code) ->
    {Size, Text} =
        case Payload of
            {some, N} when is_integer(N), N >= 0 -> {N, <<>>};
            {some, T} when is_binary(T) -> {none, T};
            _ -> {none, <<>>}
        end,
    {ok, {error, Code, Size, Text}};
answer(_) ->
    error.
