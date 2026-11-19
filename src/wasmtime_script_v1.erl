-module(wasmtime_script_v1).
-moduledoc """
The `script_v1` profile: how a shipped adapter hands a script its context
and reads its result back. erlang_wasm's `wasm_script_v1`.

A script exports `main(context)`. The adapter stages a bootstrap, the
source and the context as files, runs the interpreter over the bootstrap,
and the bootstrap prints the result on stdout as one JSON line behind a
marker minted for the request: `{"ok": Result}` or `{"error": {"code":
Code, "message": Message}}`. What the script printed before the marker is
its own output.

The marker separates, it does not authenticate: a script that learns it
(it is in `argv`) can print a result of its own. The result is the
script's either way.
""".

-export([version/0, marker/0, encode_context/1, decode_combined/2, error/3, codes/0]).
-export([stage_all/2, combined_outcome/2, boot/1]).

-doc "The profile's version.".
-spec version() -> binary().
version() -> ~"1".

-doc "A fresh delimiter for one request: sixteen random bytes in hex, so it survives `argv`.".
-spec marker() -> binary().
marker() -> binary:encode_hex(crypto:strong_rand_bytes(16), lowercase).

-doc "The context, as the bytes a guest will parse.".
-spec encode_context(term()) -> binary().
encode_context(Context) -> iolist_to_binary(json:encode(Context)).

-doc "The bootstrap for a language, from the application's `priv/script_v1`: `js` or `py`.".
-spec boot(js | py) -> binary().
boot(Language) ->
    Name = "boot." ++ atom_to_list(Language),
    {ok, Bytes} = file:read_file(
        filename:join([code:priv_dir(erlang_wasmtime), "script_v1", Name])
    ),
    Bytes.

-doc """
Split a combined stream into the script's output and the framed result.
Read from the last marker, so a script that prints something marker-shaped
cannot cut its own result short by accident.
""".
-spec decode_combined(binary(), binary()) ->
    {ok, #{result := term(), stdout := binary()}} | {error, binary(), binary()}.
decode_combined(Stdout, Marker) ->
    maybe
        {Before, After} ?= last_split(Stdout, Marker),
        {ok, Json} ?= json_of(strip_newline(After)),
        {ok, Result} ?= envelope(Json),
        {ok, #{result => Result, stdout => Before}}
    else
        nomatch -> {error, ~"no_result", ~"the guest framed no result"};
        error -> {error, ~"bad_result", ~"the framed result is not JSON"};
        {error, _, _} = Error -> Error
    end.

-doc "A profile error: always `adapter_failure`, with the profile's code in `ctx.code`.".
-spec error(binary(), binary(), map()) -> wasmtime_worker_error:worker_error().
error(Code, Message, Ctx) ->
    wasmtime_worker_error:adapter(adapter_failure, Message, Ctx#{code => Code}).

-doc "Every code this profile defines.".
-spec codes() -> [binary()].
codes() -> [~"no_entry_point", ~"exception", ~"bad_result", ~"no_result"].

-doc "Stage each file in the `ro` mount, in order, and stop at the first error.".
-spec stage_all(fun((atom(), binary(), iodata()) -> ok | {error, map()}), [{binary(), iodata()}]) ->
    ok | {error, wasmtime_worker_error:worker_error()}.
stage_all(_Stage, []) ->
    ok;
stage_all(Stage, [{Path, Bytes} | Rest]) ->
    case Stage(ro, Path, Bytes) of
        ok -> stage_all(Stage, Rest);
        {error, _} = Error -> Error
    end.

-doc """
An adapter's `decode/2` on the combined transport: a clean exit or a return
is read from stdout with the marker, any other exit is an `exit` error, a
trap is the runtime's error.
""".
-spec combined_outcome(wasmtime_worker_adapter:execution_result(), binary()) ->
    wasmtime_worker_adapter:outcome().
combined_outcome(#{outcome := returned} = R, Marker) ->
    combined_outcome(R#{outcome := exited, exit := 0}, Marker);
combined_outcome(#{outcome := exited, exit := 0, channels := Channels}, Marker) ->
    #{stdout := Out, stderr := Err} = Channels,
    case decode_combined(Out, Marker) of
        {ok, #{result := Result, stdout := Printed}} ->
            {ok, #{result => Result, stdout => Printed, stderr => Err}};
        {error, Code, Message} ->
            {error, ?MODULE:error(Code, Message, #{stdout => Out, stderr => Err})}
    end;
combined_outcome(#{outcome := exited, exit := Code, channels := Channels}, _Marker) ->
    #{stdout := Out, stderr := Err} = Channels,
    {error,
        wasmtime_worker_error:adapter(exit, ~"the engine exited non-zero", #{
            code => Code, stdout => Out, stderr => Err
        })};
combined_outcome(#{outcome := trapped, error := undefined}, _Marker) ->
    {error, wasmtime_worker_error:adapter(adapter_failure, ~"trapped with no error", #{})};
combined_outcome(#{outcome := trapped, error := Error}, _Marker) ->
    {error, wasmtime_worker_error:runtime(Error)}.

envelope(#{~"ok" := Result}) ->
    {ok, Result};
envelope(#{~"error" := #{~"code" := Code, ~"message" := Message}}) when
    is_binary(Code), is_binary(Message)
->
    case lists:member(Code, codes()) of
        true -> {error, Code, Message};
        false -> {error, ~"bad_result", ~"the result names no known code"}
    end;
envelope(_Other) ->
    {error, ~"bad_result", ~"the result is not a script_v1 envelope"}.

last_split(Bin, Marker) ->
    case binary:matches(Bin, Marker) of
        [] ->
            nomatch;
        Matches ->
            {Start, Len} = lists:last(Matches),
            {
                binary:part(Bin, 0, Start),
                binary:part(Bin, Start + Len, byte_size(Bin) - Start - Len)
            }
    end.

strip_newline(<<>>) ->
    <<>>;
strip_newline(Bin) ->
    case binary:last(Bin) of
        $\n -> binary:part(Bin, 0, byte_size(Bin) - 1);
        _ -> Bin
    end.

json_of(<<>>) ->
    error;
json_of(Bin) ->
    try
        {ok, json:decode(Bin)}
    catch
        _:_ -> error
    end.
