-module(wasmtime_http_serve).
-moduledoc false.
%% Requests given to a component's `wasi:http` handler: what
%% wasmtime_wasi_preview2:run_serve/3 and preview3's do. The response arrives
%% in parts, in this process, while the guest makes it; stream/4 hands them on
%% and run/3 collects them.

-export([run/3, stream/4]).

-export_type([request/0, result/0, part/0]).

-type request() :: wasmtime_wasi_preview2:serve_request().
-type result() :: wasmtime_wasi_preview2:serve_result().
-type headers() :: [{binary(), binary()}].

-type part() ::
    {head, 0..65535, headers()} | {chunk, binary()} | {done, headers()}.

%% the bound on a body the host holds, as erlang_wasm's
-define(DEFAULT_BODY_LIMIT, 8 * 1024 * 1024).
-define(METHODS, [
    ~"GET", ~"HEAD", ~"POST", ~"PUT", ~"DELETE", ~"CONNECT", ~"OPTIONS", ~"TRACE", ~"PATCH"
]).

-spec run(binary() | wasmtime_component:prepared(), request(), map()) -> result().
run(Component, Request, Options) ->
    Max = maps:get(http_max_body_bytes, Options, ?DEFAULT_BODY_LIMIT),
    Key = {?MODULE, make_ref()},
    _ = put(Key, #{head => undefined, body => [], size => 0, trailers => []}),
    Collect = fun(Part) -> collect(Key, Max, Part) end,
    try serve(Component, Request, Options, Collect) of
        {served, Version} ->
            response(Version, get(Key));
        stopped ->
            {error, {~"HTTP-response-body-size", {some, Max}}};
        {error, _} = Error ->
            Error
    after
        erase(Key)
    end.

%% Emit runs in this process for each part, and the guest waits for it to
%% return. A fun that raises ends the request.
-spec stream(binary() | wasmtime_component:prepared(), request(), map(), fun((part()) -> ok)) ->
    streamed | {error, term()}.
stream(Component, Request, Options, Emit) ->
    Hand = fun(Part) ->
        ok = Emit(Part),
        true
    end,
    case serve(Component, Request, Options, Hand) of
        {served, _} -> streamed;
        stopped -> {error, stopped};
        {error, _} = Error -> Error
    end.

collect(Key, _Max, {head, Status, Headers}) ->
    _ = put(Key, (get(Key))#{head := {Status, Headers}}),
    true;
collect(Key, Max, {chunk, Bytes}) ->
    #{body := Body, size := Size} = State = get(Key),
    case Size + byte_size(Bytes) of
        Total when Total =< Max ->
            _ = put(Key, State#{body := [Body, Bytes], size := Total}),
            true;
        _ ->
            false
    end;
collect(Key, _Max, {done, Trailers}) ->
    _ = put(Key, (get(Key))#{trailers := Trailers}),
    true.

%% WASI 0.2 answers without trailers, as erlang_wasm does.
response(Version, #{head := {Status, Headers}, body := Body, trailers := Trailers}) ->
    Bytes = iolist_to_binary(Body),
    case {Version, Trailers} of
        {p3, [_ | _]} -> {ok, Status, Headers, Bytes, Trailers};
        _ -> {ok, Status, Headers, Bytes}
    end.

%% {served, p2 | p3} | stopped | {error, _}
serve(Component, Request, Options, Take) ->
    maybe
        ok ?= available(),
        {ok, Wire} ?= wire(Request),
        wasmtime_wasi_preview2:with_instance(
            Component,
            Options,
            fun(Wasi) -> Wasi#{http => linked(maps:get(network, Wasi))} end,
            fun(Module, Inst) -> handle(Module, Inst, Wire, Take) end
        )
    end.

available() ->
    case wasmtime:features() of
        #{wasi_http_serve := true} ->
            ok;
        #{wasi_http_serve := false} ->
            wasmtime_error:new(link, unavailable, ~"this library cannot serve HTTP requests")
    end.

%% A handler imports `wasi:http` whether or not it sends anything: link it,
%% and let nothing out without a grant.
linked(none) -> deny;
linked(Grant) -> Grant.

handle(Module, Inst, Wire, Take) ->
    case wasmtime:serve_http(Inst, Wire, Take) of
        {ok, {served, Version, _}} ->
            {served, Version};
        {ok, {stopped, _, _}} ->
            stopped;
        {ok, {no_handler, _, _}} ->
            {error, no_incoming_handler};
        {ok, {no_response, _, _}} ->
            {error, no_response};
        {ok, {error_code, _, Detail}} ->
            {error, error_code(Detail)};
        {ok, {bad_request, _, Why}} ->
            wasmtime_error:new(link, badarg, Why);
        {error, #{class := trap, kind := Kind}} = Error when Kind =/= interrupt ->
            %% erlang_wasm: a 0.2 handler that traps before answering has
            %% answered nothing
            case is_p2(Module) of
                true -> {error, no_response};
                false -> Error
            end;
        {error, _} = Error ->
            Error
    end.

is_p2(Module) ->
    not lists:any(
        fun
            (<<"wasi:http/handler@0.3", _/binary>>) -> true;
            (_) -> false
        end,
        maps:keys(wasmtime:exports(Module))
    ).

wire(#{method := Method, path := Path} = Request) when is_binary(Method), is_binary(Path) ->
    Scheme = maps:get(scheme, Request, ~"http"),
    Authority = maps:get(authority, Request, ~"localhost"),
    Headers = maps:get(headers, Request, []),
    Trailers = maps:get(trailers, Request, []),
    try
        true = is_binary(Scheme) andalso is_binary(Authority),
        true = fields(Headers) andalso fields(Trailers),
        Body = iolist_to_binary(maps:get(body, Request, <<>>)),
        {ok, {method(Method), Scheme, Authority, Path, Headers, Body, Trailers}}
    catch
        error:_ -> bad_request()
    end;
wire(_) ->
    bad_request().

bad_request() ->
    wasmtime_error:new(link, badarg, ~"the HTTP request is malformed").

fields(List) ->
    lists:all(
        fun
            ({Name, Value}) -> is_binary(Name) andalso is_binary(Value);
            (_) -> false
        end,
        List
    ).

%% The standard methods in any case, as erlang_wasm takes them.
method(Method) ->
    Upper = string:uppercase(Method),
    case lists:member(Upper, ?METHODS) of
        true -> Upper;
        false -> Method
    end.

%% `HttpResponseBodySize(Some(4))`, as the library prints an error code, to
%% erlang_wasm's {~"HTTP-response-body-size", {some, 4}}. The records some
%% codes carry are not translated.
error_code(Detail) ->
    Pattern = ~B"^(?:ErrorCode::)?([A-Za-z]+)(?:\((.*)\))?",
    {match, [Name, Payload]} = re:run(Detail, Pattern, [{capture, [1, 2], binary}, dotall]),
    {case_name(Name), payload(Payload)}.

case_name(Name) ->
    {match, Words} = re:run(Name, ~"[A-Z][a-z]*", [global, {capture, first, binary}]),
    iolist_to_binary(lists:join($-, [word(W) || [W] <- Words])).

word(~"Dns") -> ~"DNS";
word(~"Tls") -> ~"TLS";
word(~"Http") -> ~"HTTP";
word(~"Ip") -> ~"IP";
word(~"Uri") -> ~"URI";
word(Word) -> string:lowercase(Word).

payload(~"None") ->
    none;
payload(<<"Some(", Rest/binary>>) ->
    Value = binary:part(Rest, 0, byte_size(Rest) - 1),
    case string:to_integer(Value) of
        {N, <<>>} when is_integer(N) -> {some, N};
        _ -> {some, string:trim(Value, both, "\"")}
    end;
payload(_) ->
    undefined.
