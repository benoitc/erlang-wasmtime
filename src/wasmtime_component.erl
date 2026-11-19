-module(wasmtime_component).
-moduledoc """
Host resources for components: the functions of erlang_wasm's
`wasm_component` that keep what stands behind a handle.

A component that imports an interface with a `resource` gets handles to
objects the host owns. A host function makes one with `host_new/2` and
returns the handle where the interface says `own<R>`; the guest passes it
back as `borrow<R>` or `own<R>`, and the host function reads it with
`host_get/1`.

```erlang
Imports = #{
    {~"example:kv/store", ~"[constructor]bucket"} => fun(_Inst, [Name]) ->
        {ok, [wasmtime_component:host_new(bucket, #{name => Name, items => []})]}
    end,
    {~"example:kv/store", ~"[method]bucket.put"} => fun(_Inst, [Handle, Item]) ->
        {ok, {bucket, #{items := Items} = B}} = wasmtime_component:host_get(Handle),
        ok = wasmtime_component:host_update(Handle, B#{items := [Item | Items]}),
        {ok, []}
    end
}.
```

The table belongs to the process that serves the host calls: the caller of
`wasmtime:call/3`, or the `host` process. When the guest drops its handle
the entry is removed for you. To be told, put a fun under `{Interface,
~"[resource-drop]<name>"}` in the import map: it gets `[Handle]` and does
the `host_drop/1` itself.

A handle is a positive integer, the resource's representation: the guest
cannot forge or read it.
""".

-export([host_new/2, host_new/3, host_get/1, host_update/2, host_drop/1, host_live/0]).

-define(HOST, '$wasmtime_host_resources').
-define(NEXT, '$wasmtime_host_next').

-doc "Keep `State` under a new handle. `Tag` names the kind of object, for `host_get/1`.".
-spec host_new(atom(), term()) -> pos_integer().
host_new(Tag, State) when is_atom(Tag) ->
    Handle =
        case get(?NEXT) of
            undefined -> 1;
            N -> N
        end,
    put(?NEXT, Handle + 1),
    put(?HOST, (host_table())#{Handle => {Tag, State}}),
    Handle.

-doc """
As `host_new/2`, with where the entry came from. erlang_wasm keeps the
origin to rebuild the object after a snapshot; here it is accepted and not
kept, since a snapshot does not cover components.
""".
-spec host_new(atom(), term(), term()) -> pos_integer().
host_new(Tag, State, _Origin) -> host_new(Tag, State).

-doc "The tag and state behind a handle, or `error` if it is not live.".
-spec host_get(pos_integer()) -> {ok, {atom(), term()}} | error.
host_get(Handle) -> maps:find(Handle, host_table()).

-doc "Replace the state behind a live handle, keeping its tag. A miss changes nothing.".
-spec host_update(pos_integer(), term()) -> ok.
host_update(Handle, State) ->
    case host_table() of
        #{Handle := {Tag, _Old}} = Table ->
            put(?HOST, Table#{Handle := {Tag, State}}),
            ok;
        _ ->
            ok
    end.

-doc "Drop a handle. A miss (double drop, unknown handle) changes nothing.".
-spec host_drop(pos_integer()) -> ok.
host_drop(Handle) ->
    put(?HOST, maps:remove(Handle, host_table())),
    ok.

-doc "The live handles of this process, sorted: for tests and teardown checks.".
-spec host_live() -> [pos_integer()].
host_live() -> lists:sort(maps:keys(host_table())).

host_table() ->
    case get(?HOST) of
        undefined -> #{};
        Table -> Table
    end.
