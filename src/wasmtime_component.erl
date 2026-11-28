-module(wasmtime_component).
-moduledoc """
erlang_wasm's `wasm_component`: instantiate and call components, and keep the
host resources they use.

```erlang
{ok, Bin} = file:read_file("greeter.wasm"),
{ok, Inst} = wasmtime_component:instantiate(Bin, #{}),
{ok, ~"hello you"} =
    wasmtime_component:call(Inst, ~"greet", {[string], string}, [~"you"]).
```

## Host resources

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
-export([host_limit/1]).
-export([decode/1, prepare/1, instantiate/1, instantiate/2, instantiate/3]).
-export([call/4, call_async/4, call_async/5, destroy/1, destroy/2, exports/1]).
-export([drop_resource/3, import_fun/2]).

-export_type([prepared/0]).

-doc "A component compiled once, for many instantiations or runs.".
-opaque prepared() :: {prepared, wasmtime:module_ref()}.

-doc """
Compile a component's bytes. erlang_wasm's `wasm_component:decode/1`: what it
answers is what `prepare/1` answers.
""".
-spec decode(binary()) -> {ok, prepared()} | {error, not_a_component | wasmtime_error:error()}.
decode(Bytes) when is_binary(Bytes) -> prepare(Bytes).

-doc """
Compile a component once, for many instantiations. `{error,
not_a_component}` for a core module.
""".
-spec prepare(binary() | prepared()) ->
    {ok, prepared()} | {error, not_a_component | wasmtime_error:error()}.
prepare({prepared, _} = Prepared) ->
    {ok, Prepared};
prepare(Bytes) when is_binary(Bytes) ->
    maybe
        {ok, Module} ?= load(Bytes),
        component ?= wasmtime:module_kind(Module),
        {ok, {prepared, Module}}
    else
        module -> {error, not_a_component};
        {error, _} = Error -> Error
    end.

%% Cached while the application runs, so the same bytes compile once.
load(Bytes) ->
    case whereis(wasmtime_module_cache) of
        undefined -> wasmtime:compile(Bytes);
        _ -> wasmtime:load(Bytes)
    end.

-doc #{equiv => instantiate(Component, #{})}.
-spec instantiate(binary() | prepared()) -> {ok, wasmtime:instance()} | {error, term()}.
instantiate(Component) -> instantiate(Component, #{}).

-doc #{equiv => instantiate(Component, Imports, #{})}.
-spec instantiate(binary() | prepared(), wasmtime:imports()) ->
    {ok, wasmtime:instance()} | {error, term()}.
instantiate(Component, Imports) -> instantiate(Component, Imports, #{}).

-doc """
Instantiate a component, as erlang_wasm's `wasm_component:instantiate/3`.

`Imports` maps `{Interface, Function}` to a host fun; `Opts` are those of
`wasmtime:instantiate/3`. What comes back is a `wasmtime:instance()`: the
functions here and those of `wasmtime` both take it.

erlang_wasm's `resource_closer` and `resource_predrop` are refused with
`kind => unsupported_option`; `loader` is `load` or `compile`.
""".
-spec instantiate(binary() | prepared(), wasmtime:imports(), map()) ->
    {ok, wasmtime:instance()} | {error, term()}.
instantiate(Component, Imports, Opts0) when is_map(Imports), is_map(Opts0) ->
    {Loader, Opts} =
        case maps:take(loader, Opts0) of
            error -> {load, Opts0};
            Taken -> Taken
        end,
    case maps:keys(maps:with([resource_closer, resource_predrop], Opts)) of
        [] ->
            maybe
                {ok, {prepared, Module}} ?= prepare_with(Loader, Component),
                wasmtime:instantiate(Module, Imports, Opts)
            end;
        Keys ->
            wasmtime_error:new(
                link, unsupported_option, ~"this runtime does not support the option", #{
                    keys => Keys
                }
            )
    end.

prepare_with(compile, Bytes) when is_binary(Bytes) ->
    maybe
        {ok, Module} ?= wasmtime:compile(Bytes),
        component ?= wasmtime:module_kind(Module),
        {ok, {prepared, Module}}
    else
        module -> {error, not_a_component};
        {error, _} = Error -> Error
    end;
prepare_with(Loader, Component) when Loader =:= load; Loader =:= compile ->
    prepare(Component).

-doc """
Call an export, as erlang_wasm's `wasm_component:call/4`. The signature is
read from the component, so `Sig` is not needed; an async export is called the
same way.
""".
-spec call(wasmtime:instance(), iodata(), {term(), term()}, [term()]) ->
    {ok, term()} | wasmtime:error().
call(Inst, Export, {_Params, _Result}, Args) -> wasmtime:call(Inst, Export, Args).

-doc #{equiv => call(Inst, Export, Sig, Args)}.
-spec call_async(wasmtime:instance(), iodata(), {term(), term()}, [term()]) ->
    {ok, term()} | wasmtime:error().
call_async(Inst, Export, Sig, Args) -> call_async(Inst, Export, Sig, Args, #{}).

-doc """
erlang_wasm's `call_async/5`, for an `async func` export. `Opts` take
`timeout` and `fuel`; erlang_wasm's stream and future producers and
`wait_hook` are refused.
""".
-spec call_async(wasmtime:instance(), iodata(), {term(), term()}, [term()], map()) ->
    {ok, term()} | wasmtime:error().
call_async(Inst, Export, {_Params, _Result}, Args, Opts) ->
    case maps:keys(maps:without([timeout, fuel], Opts)) of
        [] ->
            wasmtime:call(Inst, Export, Args, Opts);
        Keys ->
            wasmtime_error:new(
                link, unsupported_option, ~"this runtime does not support the option", #{
                    keys => Keys
                }
            )
    end.

-doc #{equiv => destroy(Inst, fun(_) -> ok end)}.
-spec destroy(wasmtime:instance()) -> ok.
destroy(Inst) -> destroy(Inst, fun(_Resource) -> ok end).

-doc """
Destroy an instance, handing `Closer` each host resource still live first.

The host resource table belongs to the process, as in erlang_wasm: keep one
live instance per process and destroy it from there.
""".
-spec destroy(wasmtime:instance(), fun(({atom(), term()}) -> term())) -> ok.
destroy(Inst, Closer) when is_function(Closer, 1) ->
    ok = wasmtime:destroy(Inst),
    lists:foreach(
        fun(Handle) ->
            case host_get(Handle) of
                {ok, Resource} -> _ = Closer(Resource);
                error -> ok
            end,
            host_drop(Handle)
        end,
        host_live()
    ).

-doc """
The names an instance exports: functions and interfaces. An interface's
functions are called as `Interface#Function`.
""".
-spec exports(wasmtime:instance()) -> [binary()].
exports(Inst) ->
    lists:sort([
        Name
     || Name := _ <- wasmtime:exports(Inst), binary:match(Name, ~"#") =:= nomatch
    ]).

-doc #{equiv => wasmtime:drop_resource(Inst, DtorExport, Handle)}.
-spec drop_resource(wasmtime:instance(), iodata(), non_neg_integer()) -> ok | wasmtime:error().
drop_resource(Inst, DtorExport, Handle) -> wasmtime:drop_resource(Inst, DtorExport, Handle).

-doc #{equiv => wasmtime:import_fun(Sig, Fun)}.
-spec import_fun(term(), fun(([term()]) -> term())) -> fun(([term()]) -> term()).
import_fun(Sig, Fun) -> wasmtime:import_fun(Sig, Fun).

-define(HOST, '$wasmtime_host_resources').
-define(NEXT, '$wasmtime_host_next').
-define(LIMIT, '$wasmtime_host_limit').

%% The `resource_limit` of the instance whose host call runs next in this
%% process.
-doc false.
-spec host_limit(non_neg_integer() | infinity) -> ok.
host_limit(Limit) ->
    _ = put(?LIMIT, Limit),
    ok.

-doc "Keep `State` under a new handle. `Tag` names the kind of object, for `host_get/1`.".
-spec host_new(atom(), term()) -> pos_integer().
host_new(Tag, State) when is_atom(Tag) ->
    ok = room(get(?LIMIT)),
    Handle =
        case get(?NEXT) of
            undefined -> 1;
            N -> N
        end,
    put(?NEXT, Handle + 1),
    put(?HOST, (host_table())#{Handle => {Tag, State}}),
    Handle.

%% `infinity`, or no instance's host call at all, bounds nothing.
room(Limit) when is_integer(Limit) ->
    case map_size(host_table()) >= Limit of
        true ->
            wasmtime_error:trap(resource_limit_reached, #{limit => Limit});
        false ->
            ok
    end;
room(_) ->
    ok.

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
