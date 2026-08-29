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
    compile/1, compile/2,
    validate/1, validate/2,
    module_options/1,
    imports/1,
    exports/1,
    serialize/1,
    deserialize/1, deserialize/2,
    instantiate/1, instantiate/2,
    call/3, call/4,
    call_async/3,
    await/2, await/3,
    interrupt/1,
    read_output/1,
    global_get/2,
    global_set/3,
    table_size/2,
    table_grow/3,
    fuel_remaining/1,
    handle_host_call/2,
    read_memory/3, read_memory/4,
    write_memory/3, write_memory/4,
    memory_size/1, memory_size/2,
    features/0,
    version/0
]).

-export_type([
    module_ref/0,
    instance/0,
    call_ref/0,
    value/0,
    error/0,
    frame/0,
    host_fun/0,
    options/0,
    compile_options/0,
    proposal/0,
    features/0
]).

-define(DEFAULT_MEMORY_LIMIT, 256 * 1024 * 1024).
-define(DEFAULT_HOST_TIMEOUT, 30000).
-define(DEFAULT_OUTPUT_LIMIT, 16 * 1024 * 1024).

%% `handle` is the NIF resource, `ref` the reference carried by every message
%% the instance thread sends to a caller.
-record(instance, {
    handle :: reference(),
    ref :: reference(),
    imports :: #{{binary(), binary()} => host_fun()}
}).

-opaque module_ref() :: reference().
-opaque instance() :: #instance{}.
-opaque call_ref() :: {call_ref, pos_integer()}.

-doc """
A WebAssembly value. `nan`, `infinity` and `neg_infinity` stand for the floats
Erlang cannot represent; a `v128` is a 16-byte binary.
""".
-type value() :: integer() | float() | nan | infinity | neg_infinity | <<_:128>>.

-doc """
Every failure has a class, a machine-readable kind and a message. Non-zero
WASI exits also carry `status`; traps carry the wasm frames in `trace`,
innermost first.
""".
-type error() ::
    {error, #{
        class := compile | link | call | trap | host | wasi | memory | global | table | exit,
        kind := atom(),
        message := binary(),
        status => integer(),
        trace => [frame()]
    }}.

-doc "One wasm frame of a trap: the function's index and byte offset, and its names when the module has them.".
-type frame() :: #{
    func_index := non_neg_integer(),
    func_offset := non_neg_integer(),
    func_name := binary() | undefined,
    module_name := binary() | undefined
}.

-doc """
What the linked Wasmtime library can do. A runtime-only build has no
`compiler` (`compile/1` and `serialize/1` answer `kind => unavailable`) and
may have no `wat` or `wasi`. See building.md, "Runtime-only builds".
""".
-type features() :: #{compiler := boolean(), wat := boolean(), wasi := boolean()}.

-doc """
Options for `compile/2`, `validate/2` and `deserialize/2`.

- `fuel`: compile with fuel metering (see `call/4`).
- `opt_level`: Cranelift's optimization level, `speed` by default; `none`
  compiles fastest, `speed_and_size` trades some speed for smaller code.
- `proposals`: WebAssembly proposals to enable or disable on top of
  Wasmtime's defaults. Disabling one makes validation refuse modules that
  use it: `#{simd => false, threads => false}` for a plugin format that
  must not need them.

Of these, only `fuel` is part of a precompiled module's compatibility
check: give it again to `deserialize/2` (or rely on `deserialize/1`, which
tries the fuel engine too). The optimization level and disabled proposals
need nothing at load time. Each distinct option set is one Wasmtime engine,
created on first use and kept; at most 32 exist per VM.
""".
-type compile_options() :: #{
    fuel => boolean(),
    opt_level => none | speed | speed_and_size,
    proposals => #{proposal() => boolean()}
}.

-doc "A WebAssembly proposal that `compile_options()` can turn on or off.".
-type proposal() ::
    simd
    | relaxed_simd
    | relaxed_simd_deterministic
    | bulk_memory
    | multi_value
    | multi_memory
    | memory64
    | tail_call
    | wide_arithmetic
    | custom_page_sizes
    | threads
    | reference_types
    | function_references
    | gc
    | exceptions.

-doc "A host function. Returns the results the guest expects, or `{error, Reason}` which traps the guest.".
-type host_fun() :: fun((instance(), [value()]) -> {ok, [value()]} | {error, term()}).

-doc """
WASI configuration. Nothing is granted by default.

- `args`, `env`: what the guest sees, or `inherit` for the VM's own.
- `dirs`: preopened directories, read-only unless `write`.
- `stdin`: end of file by default; a file, the VM's stdin, or bytes.
- `stdout`, `stderr`: discarded by default; a file, the VM's own, or
  `capture` into memory, read with `read_output/1`.
- `output_limit`: bytes kept per captured stream (default 16 MB); the guest
  never sees a short write, `read_output/1` reports what was dropped.
""".
-type wasi_options() :: #{
    args => inherit | [iodata()],
    env => inherit | [{iodata(), iodata()}],
    dirs => [{Guest :: iodata(), Host :: iodata(), read | write}],
    stdin => none | inherit | {file, iodata()} | {binary, iodata()},
    stdout => none | inherit | {file, iodata()} | capture,
    stderr => none | inherit | {file, iodata()} | capture,
    output_limit => pos_integer()
}.

-type options() :: #{
    imports => #{{binary(), binary()} => host_fun()},
    wasi => wasi_options(),
    memory_limit => pos_integer() | unlimited,
    max_tables => pos_integer() | unlimited,
    max_table_elements => pos_integer() | unlimited,
    max_instances => pos_integer() | unlimited,
    host_timeout => timeout(),
    host => pid()
}.

%% ------------------------------------------------------------------ modules

-doc """
Compile a module from its binary form, or from text as `{wat, Text}`.

Compilation runs on a dirty CPU scheduler. The result is immutable and can be
instantiated any number of times, from any process.

A runtime-only build has no compiler: this returns
`{error, #{kind := unavailable}}` and modules come from `deserialize/1`.
""".
-spec compile(binary() | {wat, iodata()}) -> {ok, module_ref()} | error().
compile(Source) -> compile(Source, #{}).

-doc "Compile with `t:compile_options/0`.".
-spec compile(binary() | {wat, iodata()}, compile_options()) -> {ok, module_ref()} | error().
compile({wat, Text}, Opts) ->
    with_key(Opts, fun(Key) -> wasmtime_nif:compile(iolist_to_binary(Text), true, Key) end);
compile(Bin, Opts) when is_binary(Bin) ->
    with_key(Opts, fun(Key) -> wasmtime_nif:compile(Bin, false, Key) end).

-doc """
Decode and validate a binary module without compiling it.

Cheaper than `compile/1` when the question is only whether the bytes are a
well-formed module; the errors have the same shape.
""".
-spec validate(binary()) -> ok | error().
validate(Bin) -> validate(Bin, #{}).

-doc "Validate against `t:compile_options/0`: with proposals disabled, a module using one is refused.".
-spec validate(binary(), compile_options()) -> ok | error().
validate(Bin, Opts) when is_binary(Bin) ->
    with_key(Opts, fun(Key) -> wasmtime_nif:validate(Bin, Key) end).

-doc "The `t:compile_options/0` a module was compiled or deserialized with.".
-spec module_options(module_ref()) -> compile_options().
module_options(Mod) -> key_to_options(wasmtime_nif:module_options(Mod)).

with_key(Opts, Fun) ->
    case compile_key(Opts) of
        {ok, Key} -> Fun(Key);
        {error, _} = Error -> Error
    end.

%% The engine key the NIF reads: {Fuel, OptLevel, [{Proposal, Bool}]} with
%% the overrides sorted, so equal maps mean the same engine. Malformed
%% options raise; a set Wasmtime would refuse when the engine is created
%% (which it does by aborting the process) is returned as an error here.
compile_key(Opts) when is_map(Opts) ->
    Fuel = maps:get(fuel, Opts, false),
    OptLevel = maps:get(opt_level, Opts, speed),
    Proposals = maps:get(proposals, Opts, #{}),
    true = is_boolean(Fuel),
    true = lists:member(OptLevel, [none, speed, speed_and_size]),
    case proposal_overrides(Proposals) of
        {ok, Overrides} -> {ok, {Fuel, OptLevel, Overrides}};
        {error, _} = Error -> Error
    end.

%% Sorted, checked, with the implications Wasmtime insists on: relaxed SIMD
%% sits on SIMD, so turning SIMD off turns relaxed SIMD off too, and asking
%% for the opposite is refused.
proposal_overrides(Proposals) when is_map(Proposals) ->
    Overrides = lists:sort(maps:to_list(Proposals)),
    lists:foreach(
        fun({P, V}) ->
            true = is_proposal(P),
            true = is_boolean(V)
        end,
        Overrides
    ),
    Simd = maps:get(simd, Proposals, true),
    Relaxed = maps:get(relaxed_simd, Proposals, false),
    if
        not Simd andalso Relaxed ->
            {error, #{
                class => compile,
                kind => badarg,
                message => ~"relaxed_simd needs simd: disable both or neither"
            }};
        not Simd ->
            {ok, lists:usort([{relaxed_simd, false} | Overrides])};
        true ->
            {ok, Overrides}
    end.

key_to_options({Fuel, OptLevel, Overrides}) ->
    #{fuel => Fuel, opt_level => OptLevel, proposals => maps:from_list(Overrides)}.

is_proposal(P) ->
    lists:member(P, [
        simd,
        relaxed_simd,
        relaxed_simd_deterministic,
        bulk_memory,
        multi_value,
        multi_memory,
        memory64,
        tail_call,
        wide_arithmetic,
        custom_page_sizes,
        threads,
        reference_types,
        function_references,
        gc,
        exceptions
    ]).

-doc """
Serialize a compiled module into Wasmtime's precompiled form.

The result loads with `deserialize/1` without compiling, on the same Wasmtime
version and a CPU with the same features. Use it to compile once at build
time and ship the output, or to keep a cache.
""".
-spec serialize(module_ref()) -> {ok, binary()} | error().
serialize(Mod) -> wasmtime_nif:serialize(Mod).

-doc """
Load a module produced by `serialize/1`.

Wasmtime verifies its own version and the CPU features the code was built
for, not the machine code itself. Only bytes that came from `serialize/1`,
from a source you trust, may be passed here; a `.wasm` file goes to
`compile/1`.
""".
-spec deserialize(binary()) -> {ok, module_ref()} | error().
deserialize(Bin) when is_binary(Bin) -> wasmtime_nif:deserialize(Bin, undefined).

-doc """
Load a module produced by `serialize/1` onto the engine for these
`t:compile_options/0`. Needed for `fuel => true` (`deserialize/1` covers
the defaults and the fuel engine on its own); the loaded module then
belongs to that engine, which `module_options/1` reports.
""".
-spec deserialize(binary(), compile_options()) -> {ok, module_ref()} | error().
deserialize(Bin, Opts) when is_binary(Bin) ->
    with_key(Opts, fun(Key) -> wasmtime_nif:deserialize(Bin, Key) end).

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
  A build without WASI (see `features/0`) answers `kind => unavailable`.
- `memory_limit`, `max_tables`, `max_table_elements`, `max_instances`:
  per-store caps enforced by Wasmtime. `unlimited` removes a cap.
- `host_timeout`: how long a host function may run before the guest traps
  (default 30 s).
- `host`: a process that serves host calls instead of the caller. It receives
  `{wasmtime_host_call, Ref, HostId, Key, Args}` messages and answers them
  with `handle_host_call/2`. Host calls made by the module's start section
  during `instantiate/2` still go to the caller.

The module's start section runs during instantiation and may call host
functions; a trap there is reported as `class => trap`. A WASI `_start` is an
ordinary export and is not run here: call it.
""".
-spec instantiate(module_ref(), options()) -> {ok, instance()} | error().
instantiate(Mod, Opts) when is_map(Opts) ->
    Imports = maps:get(imports, Opts, #{}),
    Ref = make_ref(),
    Id = erlang:unique_integer([positive, monotonic]),
    case wasmtime_nif:instantiate(Mod, nif_options(Imports, Opts), Ref, Id) of
        {ok, Handle} ->
            Inst = #instance{handle = Handle, ref = Ref, imports = Imports},
            case wait_result(Inst, Id, infinity) of
                ok -> {ok, Inst};
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

%% The tuple the NIF reads; see do_instantiate in wasmtime_nif.c.
nif_options(Imports, Opts) ->
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
    HostPid = maps:get(host, Opts, undefined),
    true = HostPid =:= undefined orelse is_pid(HostPid),
    {maps:keys(Imports), wasi_options(maps:get(wasi, Opts, none)), Limits, HostTimeout, HostPid}.

limit(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        unlimited -> -1;
        N when is_integer(N), N > 0 -> N
    end.

wasi_options(none) ->
    none;
wasi_options(Wasi) when is_map(Wasi) ->
    {
        case maps:get(args, Wasi, []) of
            inherit -> inherit;
            Args -> [bin(A) || A <- Args]
        end,
        case maps:get(env, Wasi, []) of
            inherit -> inherit;
            Env -> [{bin(K), bin(V)} || {K, V} <- Env]
        end,
        [{bin(Guest), bin(Host), Perm} || {Guest, Host, Perm} <- maps:get(dirs, Wasi, [])],
        stdio(maps:get(stdin, Wasi, none)),
        stdio(maps:get(stdout, Wasi, none)),
        stdio(maps:get(stderr, Wasi, none)),
        maps:get(output_limit, Wasi, ?DEFAULT_OUTPUT_LIMIT)
    }.

stdio(none) -> none;
stdio(inherit) -> inherit;
stdio(capture) -> capture;
stdio({file, Path}) -> {file, bin(Path)};
stdio({binary, Bytes}) -> {binary, iolist_to_binary(Bytes)}.

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
With `fuel` the call may execute that many units of fuel (about one per
instruction) before it traps with `kind := out_of_fuel`; the module must have
been compiled with `fuel => true`.

`timeout` covers guest execution and the wait for it. It cannot fire while
this process is inside one of its own host functions; `host_timeout` (an
instantiate option) is what bounds the guest there.
""".
-spec call(instance(), iodata(), [value()], #{timeout => timeout(), fuel => non_neg_integer()}) ->
    {ok, [value()]} | error().
call(#instance{handle = H} = Inst, Name, Args, Opts) when is_list(Args), is_map(Opts) ->
    Id = erlang:unique_integer([positive, monotonic]),
    case wasmtime_nif:call(H, iolist_to_binary(Name), Args, Id, maps:get(fuel, Opts, undefined)) of
        enqueued -> wait_result(Inst, Id, maps:get(timeout, Opts, infinity));
        {error, _} = Error -> Error
    end.

-doc """
Interrupt the call running on the instance, from any process.

The call fails with `{error, #{class := trap, kind := interrupt}}` within one
epoch tick (10 ms), or at once if it is waiting inside a host function.
Returns `not_running` when the instance is idle.
""".
-spec interrupt(instance()) -> ok | not_running.
interrupt(#instance{handle = H}) -> wasmtime_nif:interrupt(H).

-doc """
Serve one host call message in a `host` process.

Call it with every `{wasmtime_host_call, Ref, HostId, Key, Args}` message the
process receives for `Inst`; it runs the import fun and replies to the guest.
Returns `ignore` for a message that is not a host call of this instance, so
it can sit in a `receive` alongside other messages.
""".
-spec handle_host_call(instance(), term()) -> ok | ignore.
handle_host_call(
    #instance{handle = H, ref = Ref, imports = Imports} = Inst,
    {wasmtime_host_call, Ref, HostId, Key, Args}
) ->
    _ = wasmtime_nif:host_reply(H, HostId, run_host(Imports, Key, Inst, Args)),
    ok;
handle_host_call(#instance{}, _) ->
    ignore.

-doc """
Start a call and return at once with a reference for `await/2,3`.

The call runs on the instance thread while this process does other work.
Host functions are still served by this process, and only while it is
inside `await/2,3` (or by the `host` process when one was given), so a
guest that calls back before `await` waits until then, within
`host_timeout`.
""".
-spec call_async(instance(), iodata(), [value()]) -> {ok, call_ref()} | error().
call_async(#instance{handle = H}, Name, Args) when is_list(Args) ->
    Id = erlang:unique_integer([positive, monotonic]),
    case wasmtime_nif:call(H, iolist_to_binary(Name), Args, Id, undefined) of
        enqueued -> {ok, {call_ref, Id}};
        {error, _} = Error -> Error
    end.

-doc #{equiv => await(Inst, Ref, infinity)}.
-spec await(instance(), call_ref()) -> {ok, [value()]} | error().
await(Inst, Ref) -> await(Inst, Ref, infinity).

-doc """
Wait for the result of `call_async/3`, serving host calls meanwhile.

Must be called by the process that started the call. With a timeout the
call is cancelled like in `call/4`.
""".
-spec await(instance(), call_ref(), timeout()) -> {ok, [value()]} | error().
await(#instance{} = Inst, {call_ref, Id}, Timeout) -> wait_result(Inst, Id, Timeout).

%% Wait for the result of request Id, serving host calls meanwhile.
wait_result(#instance{handle = H, ref = Ref, imports = Imports} = Inst, Id, Timeout) ->
    receive
        {wasmtime_result, Ref, Id, Result} ->
            Result;
        {wasmtime_host_call, Ref, HostId, Key, Args} ->
            _ = wasmtime_nif:host_reply(H, HostId, run_host(Imports, Key, Inst, Args)),
            wait_result(Inst, Id, Timeout)
    after Timeout ->
        %% cancel/2 ends request Id and drops its result. `not_running` means
        %% it had already finished: the result is in the mailbox, so it is
        %% the answer after all.
        case wasmtime_nif:cancel(H, Id) of
            ok ->
                settle(Inst, Id),
                timeout_error();
            not_running ->
                receive
                    {wasmtime_result, Ref, Id, Result} -> Result
                after 0 -> timeout_error()
                end
        end
    end.

timeout_error() ->
    {error, #{class => trap, kind => timeout, message => ~"call timed out"}}.

%% After a cancel no result message follows, but a host call sent before the
%% cancel may still be queued; answer it so nothing lingers.
settle(#instance{handle = H, ref = Ref} = Inst, Id) ->
    receive
        {wasmtime_result, Ref, Id, _} ->
            ok;
        {wasmtime_host_call, Ref, HostId, _, _} ->
            _ = wasmtime_nif:host_reply(H, HostId, {error, ~"interrupted"}),
            settle(Inst, Id)
    after 0 -> ok
    end.

run_host(Imports, Key, Inst, Args) ->
    try (maps:get(Key, Imports))(Inst, Args) of
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

-doc "Read an exported global. Reference-typed globals are refused.".
-spec global_get(instance(), iodata()) -> {ok, value()} | error().
global_get(#instance{handle = H}, Name) -> wasmtime_nif:global_get(H, Name).

-doc "Write an exported mutable global; `kind => immutable` for a constant one.".
-spec global_set(instance(), iodata(), value()) -> ok | error().
global_set(#instance{handle = H}, Name, Value) -> wasmtime_nif:global_set(H, Name, Value).

-doc "Number of elements in an exported table.".
-spec table_size(instance(), iodata()) -> {ok, non_neg_integer()} | error().
table_size(#instance{handle = H}, Name) -> wasmtime_nif:table_size(H, Name).

-doc "Grow an exported table by `Delta` null elements; returns the previous size.".
-spec table_grow(instance(), iodata(), non_neg_integer()) -> {ok, non_neg_integer()} | error().
table_grow(#instance{handle = H}, Name, Delta) -> wasmtime_nif:table_grow(H, Name, Delta).

-doc "Fuel left after the last call, for a module compiled with `fuel => true`.".
-spec fuel_remaining(instance()) -> {ok, non_neg_integer()} | error().
fuel_remaining(#instance{handle = H}) -> wasmtime_nif:fuel_remaining(H).

-doc """
Take what the captured `stdout` and `stderr` hold and empty them.

Returns `{ok, {Stdout, Stderr, {DroppedOut, DroppedErr}}}`; the counters say
how many bytes went past `output_limit`. Works while the guest runs, so a
long-running guest's output can be drained from another process.
""".
-spec read_output(instance()) ->
    {ok, {binary(), binary(), {non_neg_integer(), non_neg_integer()}}}.
read_output(#instance{handle = H}) -> wasmtime_nif:read_output(H).

-doc """
Read `Len` bytes at `Ptr` from the instance's default memory: the export
named `memory`, or the first exported memory.

Works while the instance is idle or while a host function runs (pass the
instance the host fun received). Fails with `kind => busy` if the guest is
executing.
""".
-spec read_memory(instance(), non_neg_integer(), non_neg_integer()) -> {ok, binary()} | error().
read_memory(Inst, Ptr, Len) -> read_memory(Inst, default, Ptr, Len).

-doc "Same as `read_memory/3` on the exported memory called `Name`.".
-spec read_memory(instance(), default | iodata(), non_neg_integer(), non_neg_integer()) ->
    {ok, binary()} | error().
read_memory(#instance{handle = H}, Name, Ptr, Len) -> wasmtime_nif:read_memory(H, Name, Ptr, Len).

-doc "Write `Data` at `Ptr` in the default memory. Same rules as `read_memory/3`.".
-spec write_memory(instance(), non_neg_integer(), iodata()) -> ok | error().
write_memory(Inst, Ptr, Data) -> write_memory(Inst, default, Ptr, Data).

-doc "Same as `write_memory/3` on the exported memory called `Name`.".
-spec write_memory(instance(), default | iodata(), non_neg_integer(), iodata()) -> ok | error().
write_memory(#instance{handle = H}, Name, Ptr, Data) ->
    wasmtime_nif:write_memory(H, Name, Ptr, Data).

-doc "Size of the default memory as `{Pages, Bytes}`.".
-spec memory_size(instance()) -> {ok, {non_neg_integer(), non_neg_integer()}} | error().
memory_size(Inst) -> memory_size(Inst, default).

-doc "Size of the exported memory called `Name` as `{Pages, Bytes}`.".
-spec memory_size(instance(), default | iodata()) ->
    {ok, {non_neg_integer(), non_neg_integer()}} | error().
memory_size(#instance{handle = H}, Name) -> wasmtime_nif:memory_size(H, Name).

-doc "What the linked Wasmtime library can do; see `t:features/0`.".
-spec features() -> features().
features() -> wasmtime_nif:features().

-doc "Version of the linked Wasmtime library.".
-spec version() -> binary().
version() -> wasmtime_nif:version().
