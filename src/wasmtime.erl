-module(wasmtime).
-moduledoc """
Run WebAssembly modules natively with Wasmtime and let them call Erlang.

```erlang
Wat = ~"(module (func (export \"add\") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))",
{ok, Mod}  = wasmtime:compile({wat, Wat}),
{ok, Inst} = wasmtime:instantiate(Mod),
{ok, [3]}  = wasmtime:call(Inst, ~"add", [1, 2]).
```

Nothing raises for guest failures: compile, link, trap, WASI and host errors
all come back as `{error, Map}` with `class`, `kind` and `message` keys.

Each instance owns one OS thread and one Wasmtime store. A call runs on that
thread while the calling process waits in `receive`; a host function (an
import backed by an Erlang fun) runs in the calling process. Only one call runs
on an instance at a time; concurrent callers are queued.
""".

-export([
    compile/1,
    imports/1,
    exports/1,
    instantiate/1, instantiate/2,
    call/3, call/4,
    interrupt/1,
    read_memory/3,
    write_memory/3,
    memory_size/1,
    version/0
]).

-export_type([module_ref/0, instance/0, value/0, error/0, host_fun/0, options/0]).

-define(DEFAULT_MEMORY_LIMIT, 256 * 1024 * 1024).
-define(DEFAULT_HOST_TIMEOUT, 30000).
-define(GRACE_MS, 5000).

-record(instance, {ref :: reference() | term(), imports :: #{{binary(), binary()} => host_fun()}}).

-opaque module_ref() :: reference().
-opaque instance() :: #instance{}.

-doc """
A WebAssembly value. `nan`, `infinity` and `neg_infinity` stand for the floats
Erlang cannot represent; a `v128` is a 16-byte binary.
""".
-type value() :: integer() | float() | nan | infinity | neg_infinity | <<_:128>>.

-doc "Every failure has a class, a machine-readable kind and a message. Non-zero WASI exits also carry `status`.".
-type error() ::
    {error, #{
        class := compile | link | call | trap | host | wasi | memory | exit,
        kind := atom(),
        message := binary(),
        status => integer()
    }}.

-doc "A host function. Returns the results the guest expects, or `{error, Reason}` which traps the guest.".
-type host_fun() :: fun((instance(), [value()]) -> {ok, [value()]} | {error, term()}).

-type wasi_options() :: #{
    args => [iodata()],
    env => [{iodata(), iodata()}],
    dirs => [{Guest :: iodata(), Host :: iodata(), read | write}],
    stdin => none | inherit | {file, iodata()},
    stdout => none | inherit | {file, iodata()},
    stderr => none | inherit | {file, iodata()}
}.

-type options() :: #{
    imports => #{{binary(), binary()} => host_fun()},
    wasi => wasi_options(),
    memory_limit => pos_integer() | unlimited,
    max_tables => pos_integer() | unlimited,
    max_table_elements => pos_integer() | unlimited,
    max_instances => pos_integer() | unlimited,
    host_timeout => timeout()
}.

%% ------------------------------------------------------------------ modules

-doc """
Compile a module from its binary form, or from text as `{wat, Text}`.

Compilation runs on a dirty CPU scheduler. The result is immutable and can be
instantiated any number of times, from any process.
""".
-spec compile(binary() | {wat, iodata()}) -> {ok, module_ref()} | error().
compile({wat, Text}) ->
    wasmtime_nif:compile(iolist_to_binary(Text), true);
compile(Bin) when is_binary(Bin) ->
    wasmtime_nif:compile(Bin, false).

-doc "List what the module imports, as `{Module, Name, Kind}`.".
-spec imports(module_ref()) -> [{binary(), binary(), func | global | table | memory | tag}].
imports(Mod) -> wasmtime_nif:module_imports(Mod).

-doc "List what the module exports, as `{Name, Kind}`.".
-spec exports(module_ref()) -> [{binary(), func | global | table | memory | tag}].
exports(Mod) -> wasmtime_nif:module_exports(Mod).

%% ---------------------------------------------------------------- instances

-doc #{equiv => instantiate(Mod, #{})}.
-spec instantiate(module_ref()) -> {ok, instance()} | error().
instantiate(Mod) -> instantiate(Mod, #{}).

-doc """
Instantiate a module in its own store and thread.

Nothing is granted by default: no host functions, no WASI, 256 MB of linear
memory at most. Options:

- `imports`: map from `{Module, Name}` to a host fun. An import the module
  needs and the map does not provide fails with `class => link`.
- `wasi`: enable WASI preview 1. See `t:wasi_options/0`; without `dirs` the
  guest has no filesystem, without `stdout`/`stderr` its output is discarded.
- `memory_limit`, `max_tables`, `max_table_elements`, `max_instances`:
  per-store caps enforced by Wasmtime. `unlimited` removes a cap.
- `host_timeout`: how long a host function may run before the guest traps
  (default 30 s).

A start function or a WASI `_start` is not run here; call it explicitly.
""".
-spec instantiate(module_ref(), options()) -> {ok, instance()} | error().
instantiate(Mod, Opts) when is_map(Opts) ->
    Imports = maps:get(imports, Opts, #{}),
    Limits = {
        limit(memory_limit, Opts, ?DEFAULT_MEMORY_LIMIT),
        limit(max_tables, Opts, 100),
        limit(max_table_elements, Opts, 10_000_000),
        limit(max_instances, Opts, 10)
    },
    HostTimeout =
        case maps:get(host_timeout, Opts, ?DEFAULT_HOST_TIMEOUT) of
            infinity -> 16#FFFFFFFF;
            T when is_integer(T), T >= 0 -> T
        end,
    NifOpts = {maps:keys(Imports), wasi_options(maps:get(wasi, Opts, none)), Limits, HostTimeout},
    Id = erlang:unique_integer([positive, monotonic]),
    case wasmtime_nif:instantiate(Mod, NifOpts, Id) of
        {ok, Ref} ->
            Inst = #instance{ref = Ref, imports = Imports},
            case await(Inst, Id, infinity) of
                ok -> {ok, Inst};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

limit(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        unlimited -> -1;
        N when is_integer(N), N > 0 -> N
    end.

wasi_options(none) ->
    none;
wasi_options(Wasi) when is_map(Wasi) ->
    {
        [bin(A) || A <- maps:get(args, Wasi, [])],
        [{bin(K), bin(V)} || {K, V} <- maps:get(env, Wasi, [])],
        [{bin(Guest), bin(Host), Perm} || {Guest, Host, Perm} <- maps:get(dirs, Wasi, [])],
        stdio(maps:get(stdin, Wasi, none)),
        stdio(maps:get(stdout, Wasi, none)),
        stdio(maps:get(stderr, Wasi, none))
    }.

stdio(none) -> none;
stdio(inherit) -> inherit;
stdio({file, Path}) -> {file, bin(Path)}.

bin(B) when is_binary(B) -> B;
bin(L) -> unicode:characters_to_binary(L).

%% -------------------------------------------------------------------- calls

-doc #{equiv => call(Inst, Name, Args, #{})}.
-spec call(instance(), iodata(), [value()]) -> {ok, [value()]} | error().
call(Inst, Name, Args) -> call(Inst, Name, Args, #{}).

-doc """
Call an exported function and wait for its results.

Host functions the guest calls run in this process, so it must be able to
receive messages until the call returns. With `timeout` the guest is
interrupted when the time is up and `{error, #{kind := timeout}}` is returned.
""".
-spec call(instance(), iodata(), [value()], #{timeout => timeout()}) -> {ok, [value()]} | error().
call(#instance{ref = Ref} = Inst, Name, Args, Opts) when is_list(Args), is_map(Opts) ->
    Id = erlang:unique_integer([positive, monotonic]),
    case wasmtime_nif:call(Ref, iolist_to_binary(Name), Args, Id) of
        enqueued -> await(Inst, Id, maps:get(timeout, Opts, infinity));
        {error, _} = Error -> Error
    end.

-doc """
Interrupt the call running on the instance, from any process.

The call fails with `{error, #{class := trap, kind := interrupt}}` within one
epoch tick (10 ms). Returns `not_running` when the instance is idle.
""".
-spec interrupt(instance()) -> ok | not_running.
interrupt(#instance{ref = Ref}) -> wasmtime_nif:interrupt(Ref).

%% Wait for the result of request Id, serving host calls meanwhile.
await(#instance{ref = Ref, imports = Imports} = Inst, Id, Timeout) ->
    receive
        {wasmtime_result, Ref, Id, Result} ->
            Result;
        {wasmtime_host_call, Ref, HostId, Key, Args} ->
            wasmtime_nif:host_reply(Ref, HostId, run_host(Imports, Key, Inst, Args)),
            await(Inst, Id, Timeout)
    after Timeout ->
        wasmtime_nif:interrupt(Ref),
        drain(Inst, Id),
        {error, #{class => trap, kind => timeout, message => ~"call timed out"}}
    end.

%% After an interrupt the late result must not stay in the mailbox.
drain(#instance{ref = Ref} = Inst, Id) ->
    receive
        {wasmtime_result, Ref, Id, _} ->
            ok;
        {wasmtime_host_call, Ref, HostId, _, _} ->
            wasmtime_nif:host_reply(Ref, HostId, {error, ~"interrupted"}),
            drain(Inst, Id)
    after ?GRACE_MS -> ok
    end.

run_host(Imports, Key, Inst, Args) ->
    Fun = maps:get(Key, Imports),
    try Fun(Inst, Args) of
        {ok, Results} when is_list(Results) -> {ok, Results};
        {error, Reason} -> {error, format_reason(Reason)};
        Other -> {error, format_reason({bad_return, Other})}
    catch
        Class:Reason:Stack ->
            {error, format_reason({Class, Reason, Stack})}
    end.

format_reason(Bin) when is_binary(Bin) -> Bin;
format_reason(Term) -> unicode:characters_to_binary(io_lib:format("~0p", [Term])).

%% ------------------------------------------------------------------- memory

-doc """
Read `Len` bytes at `Ptr` from the instance's exported memory.

Works while the instance is idle or while a host function runs (pass the
instance the host fun received). Fails with `kind => busy` if the guest is
executing.
""".
-spec read_memory(instance(), non_neg_integer(), non_neg_integer()) -> {ok, binary()} | error().
read_memory(#instance{ref = Ref}, Ptr, Len) -> wasmtime_nif:read_memory(Ref, Ptr, Len).

-doc "Write `Data` at `Ptr` in the instance's exported memory. Same rules as `read_memory/3`.".
-spec write_memory(instance(), non_neg_integer(), iodata()) -> ok | error().
write_memory(#instance{ref = Ref}, Ptr, Data) -> wasmtime_nif:write_memory(Ref, Ptr, Data).

-doc "Size of the exported memory as `{Pages, Bytes}`.".
-spec memory_size(instance()) -> {ok, {non_neg_integer(), non_neg_integer()}} | error().
memory_size(#instance{ref = Ref}) -> wasmtime_nif:memory_size(Ref).

-doc "Version of the linked Wasmtime library.".
-spec version() -> binary().
version() -> wasmtime_nif:version().
