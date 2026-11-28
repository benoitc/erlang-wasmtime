-module(wasmtime_error).
-moduledoc """
The errors `wasmtime` answers with: erlang_wasm's `wasm_error`.

Read this when you are deciding what to match on. Every failure is
`{error, #{class, kind, msg, ctx}}`, with one of five classes:

- `malformed`: the bytes could not be decoded
- `invalid`: they decoded but did not validate, or a snapshot was refused
- `link`: instantiation failed, or the call could not be made
- `trap`: execution trapped
- `exhaustion`: a limit stopped the guest

Match on `class` and `kind`; both are atoms and neither comes from guest
data. `msg` is a short text for people and `ctx` holds what helps diagnose
it: `detail` is Wasmtime's own wording, `trace` the wasm frames of a trap,
`wasi_exit` the status of a program that called `proc_exit`.

```erlang
case wasmtime:call(Inst, ~"run", []) of
    {ok, Results} -> {ok, Results};
    {error, #{class := exhaustion, kind := out_of_fuel}} -> over_budget;
    {error, Error} -> logger:error("~ts", [wasmtime_error:format(Error)])
end.
```

`trap/1,2` and the other constructors throw, and `capture/1,2` turns that
throw back into a value, so code written around `wasm_error` runs unchanged.
""".

-export([
    malformed/2, malformed/3,
    invalid/2, invalid/3,
    link_error/2, link_error/3,
    trap/1, trap/2,
    exhaustion/1, exhaustion/2
]).
-export([capture/1, capture/2, format/1, is_error/1]).
-export([add_context/2]).
-export([new/3, new/4]).

-export_type([class/0, error/0, trap_reason/0]).

-type class() :: malformed | invalid | link | trap | exhaustion.

-type error() :: #{
    class := class(),
    kind := atom(),
    msg := binary(),
    ctx := map()
}.

-type trap_reason() ::
    unreachable
    | integer_divide_by_zero
    | integer_overflow
    | invalid_conversion_to_integer
    | out_of_bounds_memory_access
    | out_of_bounds_table_access
    | uninitialized_element
    | indirect_call_type_mismatch
    | atom()
    | {host_error, term()}.

-doc "An error as a value, without throwing it.".
-spec new(class(), atom(), binary()) -> {error, error()}.
new(Class, Kind, Msg) -> new(Class, Kind, Msg, #{}).

-doc "As `new/3`, with context.".
-spec new(class(), atom(), binary(), map()) -> {error, error()}.
new(Class, Kind, Msg, Ctx) ->
    {error, #{class => Class, kind => Kind, msg => Msg, ctx => Ctx}}.

-doc #{equiv => malformed(Kind, Msg, #{})}.
-spec malformed(atom(), binary()) -> no_return().
malformed(Kind, Msg) -> malformed(Kind, Msg, #{}).

-doc "Throw: the bytes are not a well-formed module.".
-spec malformed(atom(), binary(), map()) -> no_return().
malformed(Kind, Msg, Ctx) -> raise(malformed, Kind, Msg, Ctx).

-doc #{equiv => invalid(Kind, Msg, #{})}.
-spec invalid(atom(), binary()) -> no_return().
invalid(Kind, Msg) -> invalid(Kind, Msg, #{}).

-doc "Throw: the module decodes but does not validate.".
-spec invalid(atom(), binary(), map()) -> no_return().
invalid(Kind, Msg, Ctx) -> raise(invalid, Kind, Msg, Ctx).

-doc #{equiv => link_error(Kind, Msg, #{})}.
-spec link_error(atom(), binary()) -> no_return().
link_error(Kind, Msg) -> link_error(Kind, Msg, #{}).

-doc "Throw: instantiation or a call cannot be made.".
-spec link_error(atom(), binary(), map()) -> no_return().
link_error(Kind, Msg, Ctx) -> raise(link, Kind, Msg, Ctx).

-doc #{equiv => trap(Reason, #{})}.
-spec trap(trap_reason()) -> no_return().
trap(Reason) -> trap(Reason, #{}).

-doc "Throw: execution trapped.".
-spec trap(trap_reason(), map()) -> no_return().
trap({host_error, _} = Reason, Ctx) ->
    raise(trap, host_error, trap_msg(Reason), Ctx);
trap(Reason, Ctx) ->
    raise(trap, Reason, trap_msg(Reason), Ctx).

-doc #{equiv => exhaustion(Kind, #{})}.
-spec exhaustion(atom()) -> no_return().
exhaustion(Kind) -> exhaustion(Kind, #{}).

-doc "Throw: a limit stopped the guest.".
-spec exhaustion(atom(), map()) -> no_return().
exhaustion(Kind, Ctx) -> raise(exhaustion, Kind, exhaustion_msg(Kind), Ctx).

-spec raise(class(), atom(), binary(), map()) -> no_return().
raise(Class, Kind, Msg, Ctx) ->
    throw({wasmtime_error, #{class => Class, kind => Kind, msg => Msg, ctx => Ctx}}).

-doc #{equiv => capture(Fun, #{})}.
-spec capture(fun(() -> Result)) -> Result | {error, error()}.
capture(Fun) -> capture(Fun, #{}).

-doc """
Run `Fun`, turning a throw of one of the constructors into `{error, Error}`.

Any other exception becomes an error too, of class `malformed` and kind
`internal`, with the exception and its stacktrace in `ctx`.
""".
-spec capture(fun(() -> Result), map()) -> Result | {error, error()}.
capture(Fun, Ctx0) ->
    try
        Fun()
    catch
        throw:{wasmtime_error, Err} ->
            {error, add_context(Err, Ctx0)};
        Class:Reason:Stack ->
            new(
                malformed,
                internal,
                ~"internal error",
                Ctx0#{exception => {Class, Reason}, stacktrace => Stack}
            )
    end.

-doc "Add fields to the context of an error, keeping what is there.".
-spec add_context(error(), map()) -> error().
add_context(#{ctx := Ctx} = Err, Extra) ->
    Err#{ctx := maps:merge(Extra, Ctx)}.

-doc "Whether this term is one of these errors.".
-spec is_error(term()) -> boolean().
is_error(#{class := Class, kind := _, msg := _, ctx := _}) ->
    lists:member(Class, [malformed, invalid, link, trap, exhaustion]);
is_error(_) ->
    false.

-doc "Render an error on one line, for your logs and test failures.".
-spec format(error()) -> iolist().
format(#{class := Class, kind := Kind, msg := Msg, ctx := Ctx}) ->
    [
        atom_to_binary(Class),
        ": ",
        first_line(Msg),
        " (",
        atom_to_binary(Kind),
        ")",
        format_ctx(Ctx)
    ].

first_line(Text) -> hd(binary:split(Text, ~"\n")).

format_ctx(Ctx) ->
    Shown = maps:with([name, module, expected, got, index, limit, wasi_exit, timeout], Ctx),
    Fields =
        case map_size(Shown) of
            0 -> [];
            _ -> [" ", io_lib:format("~0tp", [Shown])]
        end,
    [Fields, format_frame(Ctx)].

format_frame(#{trace := [#{func_index := Index, func_name := Name} | _]}) ->
    [" in ", frame_name(Name, Index)];
format_frame(_) ->
    [].

frame_name(undefined, Index) -> ["func ", integer_to_binary(Index)];
frame_name(Name, _) -> Name.

trap_msg(unreachable) -> ~"unreachable";
trap_msg(integer_divide_by_zero) -> ~"integer divide by zero";
trap_msg(integer_overflow) -> ~"integer overflow";
trap_msg(invalid_conversion_to_integer) -> ~"invalid conversion to integer";
trap_msg(out_of_bounds_memory_access) -> ~"out of bounds memory access";
trap_msg(out_of_bounds_table_access) -> ~"out of bounds table access";
trap_msg(undefined_element) -> ~"undefined element";
trap_msg(uninitialized_element) -> ~"uninitialized element";
trap_msg(indirect_call_type_mismatch) -> ~"indirect call type mismatch";
trap_msg({host_error, _}) -> ~"host error";
trap_msg(Other) when is_atom(Other) -> atom_to_binary(Other).

exhaustion_msg(call_stack_exhausted) -> ~"call stack exhausted";
exhaustion_msg(out_of_fuel) -> ~"out of fuel";
exhaustion_msg(memory_limit) -> ~"memory limit exceeded";
exhaustion_msg(table_limit) -> ~"table limit exceeded";
exhaustion_msg(host_call_limit) -> ~"host call limit exceeded";
exhaustion_msg(Other) -> atom_to_binary(Other).
