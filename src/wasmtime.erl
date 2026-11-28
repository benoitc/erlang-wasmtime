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
    load/1, load/2,
    load_file/1,
    unload/1,
    compile/1, compile/2,
    wat2wasm/1,
    validate/1, validate/2,
    module_options/1,
    module_kind/1,
    imports/1,
    exports/1,
    extern/2,
    func_type_of/2,
    func_types_of/1,
    serialize/1,
    deserialize/1, deserialize/2,
    deserialize_file/1, deserialize_file/2,
    preinit/3,
    instantiate/1, instantiate/2, instantiate/3,
    call/3, call/4,
    call_ref/3, call_ref/4,
    call_async/3,
    await/2, await/3,
    interrupt/1,
    destroy/1,
    drop_resource/2, drop_resource/3,
    import_fun/2,
    run/1, run/2,
    read_output/1,
    get_global/2,
    global_get/2,
    global_set/3,
    table_size/2,
    table_get/3,
    table_set/4,
    table_grow/3, table_grow/4,
    ref_info/1,
    externref/2,
    externref_data/1,
    struct_get/2,
    struct_set/3,
    array_len/1,
    array_get/2,
    array_set/3,
    gc/1,
    fuel_remaining/1,
    handle_host_call/2,
    send/2,
    close/1,
    ref/1,
    read_memory/3, read_memory/4,
    write_memory/3, write_memory/4,
    memory_size/1, memory_size/2,
    snapshot/1, snapshot/2,
    restore/3,
    snapshot_info/1,
    save_snapshot/2,
    load_snapshot/2,
    acquire/1,
    release/1,
    pin/2,
    release/2,
    release_all/1,
    format_error/1,
    features/0,
    version/0
]).

-deprecated([{global_get, 2, "use get_global/2"}]).

-export_type([
    module_ref/0,
    instance/0,
    call_ref/0,
    value/0,
    ref/0,
    error/0,
    frame/0,
    host_fun/0,
    host_context/0,
    extern/0,
    imports/0,
    snapshot/0,
    valtype/0,
    options/0,
    compile_options/0,
    proposal/0,
    features/0,
    preinit_call/0,
    preinit_options/0
]).
-export([handle/1, serve_http/3]).

-define(DEFAULT_MEMORY_LIMIT, 256 * 1024 * 1024).
-define(DEFAULT_HOST_TIMEOUT, 30000).
-define(DEFAULT_INBOX_LIMIT, 16 * 1024 * 1024).

%% `handle` is the NIF resource, `ref` the reference carried by every message
%% the instance thread sends to a caller.
-record(instance, {
    handle :: reference(),
    ref :: reference(),
    imports :: #{{binary(), binary()} => host_fun()},
    kind = module :: module | component,
    %% for exports/1 on an instance
    module :: reference() | undefined,
    %% `timeout` and `fuel` given at instantiate: the defaults of every call
    defaults = #{} :: #{timeout => timeout(), fuel => non_neg_integer()},
    %% made with `snapshotable => true`: what snapshot/2 needs
    snap :: undefined | map(),
    %% live host resources the process serving its host calls may hold
    resource_limit = infinity :: non_neg_integer() | infinity,
    %% `stdout` and `stderr` given as a pid, device or fun, and the `stream`
    %% process for what has no sink
    sinks = #{} :: wasmtime_wasi_config:sinks(),
    stream :: pid() | undefined
}).

-record(snapshot, {
    %% the module that starts in the captured state, compiled
    module :: reference(),
    %% its binary form, for save_snapshot/2
    wasm :: binary(),
    %% sha256 of the bytes of the module it was captured from
    source :: binary(),
    version :: term(),
    key :: term()
}).

-opaque module_ref() :: reference().
-opaque instance() :: #instance{}.
-doc "An image of an initialized instance, from `snapshot/1,2` or `load_snapshot/2`.".
-opaque snapshot() :: #snapshot{}.
-opaque call_ref() :: {call_ref, pos_integer()}.

-doc """
A WebAssembly value. `nan`, `infinity` and `neg_infinity` stand for the floats
Erlang cannot represent; a `v128` is a 16-byte binary.
""".
-type value() ::
    integer()
    | float()
    | nan
    | infinity
    | neg_infinity
    | <<_:128>>
    | null
    | ref()
    | {i31, integer()}.

-doc """
A reference the guest handed out: a `funcref`, an `externref` or a GC value
(`struct`, `array`, any other `anyref`). Opaque; `ref_info/1` says which.
The object stays alive while the term does; drop the term to let the
guest's collector reclaim it. A ref belongs to one instance.
""".
-opaque ref() :: reference().

-doc """
Every failure has a class, a machine-readable kind, a message and a context
map, as erlang_wasm's errors do; see `wasmtime_error`. A trap carries the
wasm frames in `ctx.trace`, innermost first, and a program that called
`proc_exit` its status in `ctx.wasi_exit`.
""".
-type error() :: {error, wasmtime_error:error()}.

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
may have no `wat` or `wasi`; `components` says whether it can load
components, and `component_async` whether it runs component async (see
components.md). See building.md, "Runtime-only builds".
""".
-type features() :: #{
    compiler := boolean(),
    wat := boolean(),
    wasi := boolean(),
    components := boolean(),
    wasi_http := boolean(),
    wasi_sockets := boolean(),
    component_async := boolean(),
    wasi_p3 := boolean(),
    wasi_limits := boolean(),
    wasi_http_serve := boolean()
}.

-doc """
Options for `compile/2`, `validate/2` and `deserialize/2`.

- `fuel`: compile with fuel metering (see `call/4`).
- `opt_level`: Cranelift's optimization level, `speed` by default; `none`
  compiles fastest, `speed_and_size` trades some speed for smaller code.
- `proposals`: WebAssembly proposals to enable or disable on top of
  Wasmtime's defaults. Disabling one makes validation refuse modules that
  use it: `#{simd => false, threads => false}` for a plugin format that
  must not need them.

- `allocator`: how instances get their memories and tables. `on_demand`
  (the default) maps them per instance. `pooling` reserves `instances`
  slots up front and reuses them, which with a pre-initialized module
  makes instantiation a remap of its image; see [preinit](preinit.md).
- `pooling`: the pool, when `allocator => pooling`. `instances` live at
  once (default 1000; one more fails to instantiate), `max_memory` per
  instance (default 256 MB, a multiple of 64 KB up to 4 GB; a guest that
  grows past it fails like one past `memory_limit`), and `keep_resident`,
  bytes of a freed slot kept mapped and zeroed rather than released
  (default 0). `core_instances`, `memories` and `tables` are the slots for
  what instances are made of, `instances` each by default: a core module
  uses one of each, a component one per core instance, memory and table it
  holds (a componentize-py agent: 16 core instances), so size them for
  components.

Of these, only `fuel` is part of a precompiled module's compatibility
check: give it again to `deserialize/2` (or rely on `deserialize/1`, which
tries the fuel engine too). The optimization level, the allocator and
disabled proposals need nothing at load time. Each distinct option set is
one Wasmtime engine, created on first use and kept; at most 32 exist per VM.
""".
-type compile_options() :: #{
    fuel => boolean(),
    opt_level => none | speed | speed_and_size,
    proposals => #{proposal() => boolean()},
    allocator => on_demand | pooling,
    pooling => #{
        instances => pos_integer(),
        max_memory => pos_integer(),
        keep_resident => non_neg_integer(),
        core_instances => pos_integer(),
        memories => pos_integer(),
        tables => pos_integer()
    }
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

-doc """
A host function. It takes a context map, whose `instance` is the instance
that called it, and the arguments, and returns the results the guest expects,
or `{trap, Reason}` which traps the guest (`{error, Reason}` does the same).
`{Module, Function}` names one. For a component import it may also take the
argument list alone and return the value itself, erlang_wasm's typed form
(`import_fun/2`); an exception then traps the guest.
""".
-type host_fun() ::
    fun(
        (host_context(), [value() | term()]) ->
            {ok, [value() | term()]} | {trap, term()} | {error, term()}
    )
    | {module(), atom()}
    | fun(([term()]) -> term()).

-doc "A function export taken with `extern/2`, to give to another instance.".
-type extern() ::
    {wasm_func, fun((term(), [value()]) -> {ok, [value()]}), {[valtype()], [valtype()]}}.

-doc "What a host function receives first. Memory functions accept it.".
-type host_context() :: #{instance := instance()}.

-doc """
WASI configuration. Nothing is granted by default.

- `args`, `env`: what the guest sees, or `inherit` for the VM's own.
- `dirs`: preopened directories, `{Guest, Host}` or `{Guest, Host, read |
  write}`, read-only unless `write`.
- `stdin`: end of file by default; a file, the VM's stdin, bytes (a binary
  or `{binary, Bytes}`), or `stream`: what `send/2` queues, as the guest
  reads it.
- `stdout`, `stderr`: discarded by default; a file, the VM's own,
  `capture` into memory, read with `read_output/1`, or `stream`: every
  write goes to the `stream` process as `{wasmtime_stream, Ref, stdout |
  stderr, Bytes}` at once. As in erlang_wasm, also a pid, which gets
  `{wasi_output, From, Bytes}`, an io device name, or a fun of the bytes:
  the process waiting for the call delivers them.
- `random`: `strong` (the default). For a core module also `{seed, N}`, the
  same bytes every run, or `none`, which answers `ENOTCAPABLE`.
- `output_limit`: bytes kept per captured stream (default 16 MB); the guest
  never sees a short write, `read_output/1` reports what was dropped.
- `clocks`: `all` (the default) or `monotonic`. With `monotonic` the guest
  reads the host's monotonic clock and every other clock (wall time,
  process and thread CPU time) answers `ENOTCAPABLE`, so it cannot learn the
  date or time of day.
- `http`: whether a component gets `wasi:http/outgoing-handler`. `none`
  (the default), `all` for any server, or a grant like `network`'s whose
  `connect` rules for `tcp` say which addresses a request may reach: the name
  is resolved once and the connection goes to an address that passed. Full
  builds only (`features/0`, `wasi_http`). A core module answers `kind =>
  unsupported`.
- `http_max_field_bytes`, `http_max_body_bytes` (components): the most one
  set of headers the guest builds may take, 128 KiB when left out, and the
  most bytes the body of a request, and of a response, may have, 8 MiB when
  left out.
- `initial_cwd` (components): the directory `wasi:cli/environment` says the
  program starts in.
- `network`: what a component may do with `wasi:sockets`. `none` (the
  default); `all`, TCP, UDP and name lookup to or from any address the node
  can reach, the loopback included; or a grant as erlang_wasm's `net`:
  `#{connect => [Rule], listen => [Rule], resolve => allow | deny, tcp =>
  boolean(), udp => boolean()}`, a `Rule` being `{tcp | udp, Address, Port |
  {First, Last} | any}` and an `Address` a tuple or a binary with an optional
  prefix length, such as `~"10.0.0.0/8"`. A library without this project's
  patches (`features/0`, `wasi_sockets` and `wasi_limits`) answers `kind =>
  unavailable`; a core module answers `kind => unsupported`.
""".
-type sink() :: pid() | atom() | fun((binary()) -> term()).

-type wasi_options() :: #{
    args => inherit | [iodata()],
    env => inherit | [{iodata(), iodata()}],
    dirs => [{Guest :: iodata(), Host :: iodata(), read | write}],
    stdin => none | inherit | stream | {file, iodata()} | {binary, iodata()} | binary(),
    stdout => none | inherit | stream | {file, iodata()} | capture | sink(),
    stderr => none | inherit | stream | {file, iodata()} | capture | sink(),
    random => strong | none | {seed, integer()},
    output_limit => pos_integer(),
    clocks => all | monotonic | [monotonic | realtime],
    network => none | all | map(),
    http => none | all | map(),
    initial_cwd => iodata(),
    http_max_field_bytes => pos_integer(),
    http_max_body_bytes => pos_integer()
}.

-doc """
A value type, spelled as erlang_wasm does. A reference to a concrete
(indexed) type answers its family: `func`, `struct`, `array` or `exn`.
""".
-type valtype() ::
    i32
    | i64
    | f32
    | f64
    | v128
    | {ref, null | nonull, atom()}.

-type imports() :: #{{binary(), binary()} => host_fun() | extern()}.

-type options() :: #{
    imports => imports(),
    wasi => wasi_options(),
    memory_limit => pos_integer() | unlimited,
    max_tables => pos_integer() | unlimited,
    max_table_elements => pos_integer() | unlimited,
    max_instances => pos_integer() | unlimited,
    timeout => timeout(),
    fuel => pos_integer() | infinity,
    max_memory_pages => non_neg_integer() | infinity,
    profile => plugin | script,
    snapshotable => boolean(),
    host_timeout => timeout(),
    host => pid(),
    resource_limit => non_neg_integer() | infinity,
    transfer_limit => non_neg_integer() | infinity,
    stream => pid(),
    inbox_limit => pos_integer()
}.

%% ------------------------------------------------------------------ modules

-doc """
Compile a module from its binary form, or from text as `{wat, Text}`.

Compilation runs on a dirty CPU scheduler. The result is immutable and can be
instantiated any number of times, from any process.

A runtime-only build has no compiler: this returns
`{error, #{kind := unavailable}}` and modules come from `deserialize/1`.

Set `max_module_bytes` in the application environment to refuse larger
sources with `kind => module_too_large`.
""".
-spec compile(binary() | {wat, iodata()}) -> {ok, module_ref()} | error().
compile(Source) -> compile(Source, #{}).

-doc "Compile with `t:compile_options/0`.".
-spec compile(binary() | {wat, iodata()}, compile_options()) -> {ok, module_ref()} | error().
compile({wat, Text}, Opts) ->
    compile_bytes(iolist_to_binary(Text), true, Opts);
compile(Bin, Opts) when is_binary(Bin) ->
    compile_bytes(Bin, false, Opts).

%% Refused before any work, as compiling costs memory and time in proportion
%% to the input. `max_module_bytes` is unlimited unless set.
compile_bytes(Bytes, Text, Opts) ->
    case application:get_env(erlang_wasmtime, max_module_bytes) of
        {ok, Max} when byte_size(Bytes) > Max ->
            wasmtime_error:new(exhaustion, module_too_large, ~"module too large", #{
                bytes => byte_size(Bytes), limit => Max
            });
        _ ->
            with_key(Opts, fun(Key) -> wasmtime_nif:compile(Bytes, Text, Key) end)
    end.

-doc #{equiv => load(Source, #{})}.
-spec load(binary() | {wat, iodata()}) -> {ok, module_ref()} | error().
load(Source) -> load(Source, #{}).

-doc """
Compile a module and keep it in the node's cache, as erlang_wasm's
`wasm:load/1,2`.

Use it instead of `compile/2` when several parts of a system load the same
bytes: the second load finds the module compiled and only takes a claim on
it. The key is the source and the compile options, so the same bytes under
other options are another module. What you get is an ordinary module:
everything that takes one takes it.

Each load is a claim held by the calling process. `unload/1` gives one
back, and a process that dies gives back all of its own. The module leaves
the cache with its last claim. The cache holds 256 modules unless
`max_resident_modules` in the application environment says otherwise; past
that, `load/2` answers `kind => cache_full`.

The environment may also set `max_resident_module_bytes`, past which a new
load answers `kind => cache_full`, and `max_module_loads_per_second`, past
which it answers `kind => load_rate_exceeded`. Both are unlimited unless set;
only loads that compile count.

The `erlang_wasmtime` application must be started: without it the answer is
`kind => not_started`.
""".
-spec load(binary() | {wat, iodata()}, compile_options()) -> {ok, module_ref()} | error().
load(Source, Opts) when is_map(Opts) -> wasmtime_module_cache:load(Source, Opts).

-doc "Read a `.wasm` or `.wat` file and `load/1` it; `kind => file_error` when it cannot be read.".
-spec load_file(file:name_all()) -> {ok, module_ref()} | error().
load_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            case filename:extension(iolist_to_binary(Path)) of
                ~".wat" -> load({wat, Bin});
                _ -> load(Bin)
            end;
        {error, Reason} ->
            wasmtime_error:new(link, file_error, ~"cannot read module file", #{
                path => Path, reason => Reason
            })
    end.

-doc """
Give back one claim on a cached module. The module stays in the cache until
every holder has done so, and stays usable for as long as you hold the term.
A module that did not come from `load/1,2` is left alone.
""".
-spec unload(module_ref()) -> ok.
unload(Mod) when is_reference(Mod) -> wasmtime_module_cache:unload(Mod).

-doc """
Translate the text format into the binary form, without compiling.

Use it when you need the bytes rather than a module: `preinit/3` and
`validate/1` take a binary.
""".
-spec wat2wasm(iodata()) -> {ok, binary()} | error().
wat2wasm(Text) -> wasmtime_nif:wat2wasm(iolist_to_binary(Text)).

-doc """
Validate a module and answer it, as erlang_wasm's `wasm:validate/1`.

Given the bytes of a module, decode and validate them without compiling,
which is cheaper than `compile/1`; the errors have the same shape. A module
you already compiled is valid and is answered as it is.
""".
-spec validate(binary() | module_ref()) -> {ok, binary() | module_ref()} | error().
validate(Source) -> validate(Source, #{}).

-doc "Validate against `t:compile_options/0`: with proposals disabled, a module using one is refused.".
-spec validate(binary() | module_ref(), compile_options()) ->
    {ok, binary() | module_ref()} | error().
validate(Bin, Opts) when is_binary(Bin) ->
    case with_key(Opts, fun(Key) -> wasmtime_nif:validate(Bin, Key) end) of
        ok -> {ok, Bin};
        {error, _} = Error -> Error
    end;
validate(Mod, _Opts) when is_reference(Mod) ->
    %% badarg for anything but a module
    _ = module_kind(Mod),
    {ok, Mod}.

-doc """
Whether a compiled module is a core module or a component.

`compile/1,2` and `deserialize/1,2` take both and tell them apart by the
binary; see [components](components.md).
""".
-spec module_kind(module_ref()) -> module | component.
module_kind(Mod) -> wasmtime_nif:module_kind(Mod).

-doc "The `t:compile_options/0` a module was compiled or deserialized with.".
-spec module_options(module_ref()) -> compile_options().
module_options(Mod) -> wasmtime_options:key_to_options(wasmtime_nif:module_options(Mod)).

with_key(Opts, Fun) ->
    case wasmtime_options:compile_key(Opts) of
        {ok, Key} -> Fun(Key);
        {error, _} = Error -> Error
    end.

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

-doc """
Load a module produced by `serialize/1` from a file, which Wasmtime maps
rather than reads.

Use this for a large module instantiated often: its memory image then
points into the mapping, so each instance maps the image copy-on-write
instead of copying it. On macOS this is the only way to get that; on Linux
`deserialize/1` gets it too, through an anonymous file. See
[preinit](preinit.md). The file must not change while the module is loaded.
The same trust rule as `deserialize/1` applies.
""".
-spec deserialize_file(file:filename_all()) -> {ok, module_ref()} | error().
deserialize_file(Path) -> wasmtime_nif:deserialize({file, bin(Path)}, undefined).

-doc "`deserialize_file/1` onto the engine for these `t:compile_options/0`.".
-spec deserialize_file(file:filename_all(), compile_options()) -> {ok, module_ref()} | error().
deserialize_file(Path, Opts) ->
    with_key(Opts, fun(Key) -> wasmtime_nif:deserialize({file, bin(Path)}, Key) end).

-doc "An init export to call during `preinit/3`: its name, or its name and arguments.".
-type preinit_call() :: iodata() | {iodata(), [value()]}.

-doc """
Options for `preinit/3`: every `t:options/0` key, given to the instance the
init calls run in, and:

- `compile`: the `t:compile_options/0` that instance is compiled with.
- `remove_exports`: exports the result must not have, such as the init
  function itself. `_initialize` is removed when it was one of the calls.
""".
-type preinit_options() :: #{
    compile => compile_options(),
    remove_exports => [iodata()],
    atom() => term()
}.

-doc """
Run a module's init exports once and return a new module that starts in the
state they left: Wizer's pre-initialization.

`Wasm` is the module's binary form. It is instantiated with `Opts` (WASI
preopens, env, host functions), then `Init` runs: a list of exports to call
in order, or a fun given the instance that returns `ok` to take the
snapshot. The result is a module binary whose memories and mutable globals
hold that state; compile it (with `allocator => pooling` to instantiate it
cheaply), `serialize/1` it and cache the `.cwasm`.

What the snapshot does not carry: open files and anything else the host
holds for the instance, so give each instance of the result the same
`dirs`, in the same order, as the init instance had. Tables must be left as
the module's element segments set them, and the module may not import
memories, tables or globals or declare GC types. See
[preinit](preinit.md).
""".
-spec preinit(binary(), preinit_options(), [preinit_call()] | fun((instance()) -> term())) ->
    {ok, binary()} | error().
preinit(Wasm, Opts, Init) -> wasmtime_preinit:run(Wasm, Opts, Init).

-doc """
Drop a resource handle a component instance handed out, running the guest's
destructor for a resource the guest defines.

The handle is gone afterwards; using it again is `kind => badarg`.
`destroy/1` drops every handle an instance still holds. See
[components](components.md).
""".
-spec drop_resource(instance(), non_neg_integer()) -> ok | error().
drop_resource(#instance{handle = H} = Inst, Handle) when is_integer(Handle) ->
    Id = erlang:unique_integer([positive, monotonic]),
    case wasmtime_nif:call(H, {drop, Handle}, [], Id, undefined) of
        enqueued ->
            case wait_result(Inst, Id, infinity) of
                {ok, _} -> ok;
                {error, _} = Error -> Error
            end;
        {error, _} = Error ->
            Error
    end.

-doc """
erlang_wasm's `drop_resource/3`: the destructor's export name is not needed
here, Wasmtime knows it from the handle.
""".
-spec drop_resource(instance(), iodata(), non_neg_integer()) -> ok | error().
drop_resource(Inst, _DtorName, Handle) -> drop_resource(Inst, Handle).

-doc """
A host function in erlang_wasm's typed form, for a component import.

`Fun` takes the list of arguments and returns the result as a term, or
`undefined` for a function without result; an exception traps the guest.
The signature is read from the component, so `Sig` is accepted for
compatibility and not needed.
""".
-spec import_fun(term(), fun(([term()]) -> term())) -> fun(([term()]) -> term()).
import_fun(_Sig, Fun) when is_function(Fun, 1) -> Fun.

-doc #{equiv => run(Inst, #{})}.
-spec run(instance()) -> ok | error().
run(Inst) -> run(Inst, #{}).

-doc """
Run a WASI 0.2 or 0.3 command component: call its `wasi:cli/run` export.

Returns `ok` when the program ends normally. `run` answering its error
case, or `exit` with a non-zero status, is `{error, #{class := trap, kind :=
host_error, ctx := #{wasi_exit := Status}}}`, as for a preview 1 program.
`Opts` are `call/4`'s.
""".
-spec run(instance(), #{timeout => timeout(), fuel => non_neg_integer()}) -> ok | error().
run(Inst, Opts) ->
    case call(Inst, ~"wasi:cli/run#run", [], Opts) of
        {ok, {ok, _}} ->
            ok;
        %% exit(0)
        {ok, undefined} ->
            ok;
        {ok, {error, _}} ->
            wasmtime_error:new(trap, host_error, ~"run returned an error", #{
                wasi_exit => 1, reason => {wasi_exit, 1}
            });
        {error, #{ctx := #{wasi_exit := 0}}} ->
            ok;
        {error, _} = Error ->
            Error
    end.

-doc false.
-spec handle(instance()) -> reference().
handle(#instance{handle = H}) -> H.

-doc "List what the module imports, as `{Module, Name, Kind}`.".
-spec imports(module_ref()) -> [{binary(), binary(), func | global | table | memory | tag}].
imports(Mod) -> wasmtime_nif:module_imports(Mod).

-doc """
What a module, or the module of an instance, exports, as erlang_wasm's
`wasm:exports/1`: `#{Name => {Kind, Index}}`. Wasmtime does not report the
index, so it is `undefined` here. A component also exports `instance`s, and
lists their functions as `Interface#Function`.
""".
-spec exports(module_ref() | instance()) -> #{binary() => {atom(), undefined}}.
exports(#instance{module = Mod}) ->
    exports(Mod);
exports(Mod) ->
    #{Name => {export_kind(Kind), undefined} || {Name, Kind} <- wasmtime_nif:module_exports(Mod)}.

export_kind(memory) -> mem;
export_kind(Kind) -> Kind.

-doc """
Take a function an instance exports in the form another module imports it, as
erlang_wasm's `wasm:extern/2`.

```erlang
{ok, Add} = wasmtime:extern(Library, ~"add"),
{ok, Inst} = wasmtime:instantiate(Mod, #{{~"lib", ~"add"} => Add}, #{}).
```

The two instances stay apart: a call crosses from one thread to the other
through the process that is waiting. An error in the export is the error of
the call that reached it. A signature that does not match the import is
`kind => incompatible_import_type`. A reference belongs to its instance, so a
function passing one answers `kind => foreign_reference`, and two instances
that call each other in a loop get `kind => reentrant`.

Only functions can be shared. A memory, table, global or tag, and anything of
a component, is `kind => unsupported_extern`; a snapshotable instance hands out
nothing (`kind => instance_snapshotable`).
""".
-spec extern(instance(), binary()) -> {ok, extern()} | error().
extern(#instance{snap = Snap}, Name) when Snap =/= undefined ->
    wasmtime_error:new(
        link, instance_snapshotable, ~"a snapshotable instance does not hand out handles", #{
            name => Name
        }
    );
extern(#instance{kind = component}, Name) ->
    unsupported_extern(Name);
extern(#instance{module = Mod} = Inst, Name) ->
    case exports(Mod) of
        #{Name := {func, _}} ->
            {ok, Type} = func_type_of(Mod, Name),
            Fun = fun(_Context, Args) ->
                case call(Inst, Name, Args) of
                    {ok, Results} -> {ok, Results};
                    {error, Error} -> erlang:throw({wasmtime_error, Error})
                end
            end,
            {ok, {wasm_func, Fun, Type}};
        #{Name := _} ->
            unsupported_extern(Name);
        #{} ->
            wasmtime_error:new(link, unknown_export, ~"unknown export", #{name => Name})
    end.

unsupported_extern(Name) ->
    wasmtime_error:new(link, unsupported_extern, ~"only core functions can be shared", #{
        name => Name
    }).

%% A function of another instance carries its type, so a mismatch is a link
%% error here and not a failed call later.
link_externs(Mod, Imports) ->
    case [Key || Key := {wasm_func, _, _} <- Imports] of
        [] ->
            {ok, Imports};
        Externs ->
            Declared =
                #{
                    {M, N} => {Params, Results}
                 || {M, N, Params, Results} <- wasmtime_nif:module_import_types(Mod)
                },
            link_externs(Externs, Declared, Imports)
    end.

link_externs([], _Declared, Imports) ->
    {ok, Imports};
link_externs([Key | Keys], Declared, Imports) ->
    #{Key := {wasm_func, Fun, Type}} = Imports,
    case Declared of
        #{Key := Other} when Other =/= Type ->
            wasmtime_error:new(link, incompatible_import_type, ~"incompatible import type", #{
                where => Key, declared => Other, provided => Type
            });
        #{} ->
            link_externs(Keys, Declared, Imports#{Key := Fun})
    end.

-doc """
The type of every function a core module exports, without instantiating it,
as erlang_wasm's `wasm:func_types_of/1`: `#{Name => {ok, {Params, Results}}}`.
Bytes that do not compile answer `{error, {undecodable_core, Error}}`.

Takes a compiled module, or what `compile/1` takes. Bytes are compiled
first, so pass the module when you already have one. A component has no core
function exports and answers an empty map.
""".
-spec func_types_of(module_ref() | binary() | {wat, iodata()}) ->
    {ok, #{binary() => {ok, {[valtype()], [valtype()]}}}}
    | {error, {undecodable_core, wasmtime_error:error()}}.
func_types_of(Source) when is_binary(Source); is_tuple(Source) ->
    case compile(Source) of
        {ok, Mod} -> func_types_of(Mod);
        {error, Error} -> {error, {undecodable_core, Error}}
    end;
func_types_of(Mod) ->
    {ok,
        #{
            Name => {ok, {Params, Results}}
         || {Name, Params, Results} <- wasmtime_nif:module_func_types(Mod)
        }}.

-doc """
The type of one function export, `{ok, {Params, Results}}`, without
instantiating. `{error, {not_a_func_export, Name}}` when the module exports
no function of that name.
""".
-spec func_type_of(module_ref() | binary() | {wat, iodata()}, binary()) ->
    {ok, {[valtype()], [valtype()]}}
    | {error, {not_a_func_export, binary()} | {undecodable_core, wasmtime_error:error()}}.
func_type_of(Source, Name) ->
    case func_types_of(Source) of
        {ok, #{Name := Type}} ->
            Type;
        {ok, _} ->
            {error, {not_a_func_export, Name}};
        {error, _} = Error ->
            Error
    end.

%% ---------------------------------------------------------------- instances

-doc #{equiv => instantiate(Mod, #{})}.
-spec instantiate(module_ref()) -> {ok, instance()} | error().
instantiate(Mod) -> instantiate(Mod, #{}).

-doc """
Instantiate a module in its own store and thread.

Nothing is granted by default: no host functions, no WASI, 256 MB of linear
memory at most. Options:

- `imports`: the import map, when you call `instantiate/2`. Deprecated:
  pass it as the second argument of `instantiate/3`.
- `wasi`: enable WASI preview 1. See `t:wasi_options/0`; without `dirs` the
  guest has no filesystem, without `stdout`/`stderr` its output is discarded.
  A build without WASI (see `features/0`) answers `kind => unavailable`.
- `memory_limit`, `max_tables`, `max_table_elements`, `max_instances`:
  per-store caps enforced by Wasmtime. `unlimited` removes a cap.
  `max_instances` counts core instances: 10 by default for a module, 100
  for a component, which holds several.
- `timeout`, `fuel`, `max_memory_pages`: the limits of `wasmtime_limits`.
  `timeout` and `fuel` become the defaults of every call on the instance,
  and bound the module's initialization too, which costs about one unit per
  byte of data. A metered module instantiated without `fuel` is initialized
  on 10,000,000 units plus one per byte of `memory_limit`, and then holds
  none.
- `resource_limit` (components): how many host resource handles may be
  live in the process serving host calls, past which `host_new` traps with
  `kind => resource_limit_reached`, and how many resources WASI may hold for
  the instance.
- `transfer_limit` (components): how many bytes one call may copy from the
  component to the host, 128 MiB when left out; past it,
  `kind => hostcall_fuel`. A list of bytes counts about 32 per byte.
- `profile`: `plugin` or `script`, erlang_wasm's compile tiers. Accepted and
  without effect: Wasmtime has one tier.
- `snapshotable`: `true` to allow `snapshot/1,2` on the instance. The module
  must come from `load/1,2`.
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
-spec instantiate(module_ref(), options() | imports()) -> {ok, instance()} | error().
instantiate(Mod, Map) when is_map(Map) ->
    %% Import keys are `{Module, Name}` tuples and option keys are atoms, so
    %% the two maps cannot be confused. An empty map is both.
    case lists:all(fun is_tuple/1, maps:keys(Map)) of
        true -> instantiate(Mod, Map, #{});
        false -> instantiate(Mod, maps:get(imports, Map, #{}), Map)
    end.

-doc """
Instantiate a module with its imports, as erlang_wasm's `wasm:instantiate/3`.

`Imports` maps `{Module, Name}` to a host fun. An import the module needs
and the map does not provide fails with `class => link`. `Opts` are the
options of `instantiate/2`; an `imports` key in it is ignored.

erlang_wasm's `link`, `snapshot_hooks`, `compile`, `compile_quality` and
`compile_after` have no equivalent here and are refused with
`kind => unsupported_option`.

```erlang
Log = fun(_Ctx, [N]) -> logger:info("got ~p", [N]), {ok, []} end,
{ok, Inst} = wasmtime:instantiate(Mod, #{{~"env", ~"log"} => Log}, #{memory_limit => 16 bsl 20}).
```
""".
-spec instantiate(module_ref(), imports(), options()) -> {ok, instance()} | error().
instantiate(Mod, Imports0, Opts0) when is_map(Imports0), is_map(Opts0) ->
    maybe
        {ok, Imports1, Opts} ?= wasmtime_wasi_config:take_imports(Imports0, Opts0),
        Imports = root_imports(Mod, Imports1),
        ok ?= check_options(Opts),
        ok ?= check_component_limits(module_kind(Mod), Opts),
        {ok, Linked} ?= link_externs(Mod, Imports),
        ok ?= check_imports(Linked),
        maybe_snapshotable(Mod, Linked, page_limit(Opts))
    end.

%% erlang_wasm's `profile` picks its compile tier. There is one tier here, so
%% a known profile is accepted and changes nothing.
check_options(#{profile := Profile}) when Profile =/= plugin, Profile =/= script ->
    wasmtime_error:new(link, unknown_profile, ~"profile must be plugin or script", #{
        profile => Profile
    });
check_options(Opts) ->
    Unsupported = [link, snapshot_hooks, compile, compile_quality, compile_after],
    case maps:keys(maps:with(Unsupported, Opts)) of
        [] -> check_limits(Opts);
        Keys -> unsupported_option(Keys)
    end.

%% The workers' limits are no limits of an instance.
check_limits(Opts) ->
    Workers = maps:keys(maps:with([max_host_calls, max_heap_words], Opts)),
    case wasmtime_limits:validate(Opts) of
        ok when Workers =:= [] ->
            ok;
        ok ->
            invalid_limits(Workers);
        {error, {invalid_limits, Bad}} ->
            invalid_limits(Bad ++ Workers)
    end.

%% A call may be given no fuel at all, so only the limits that are never
%% enforced are refused here.
check_call_limits(Opts) ->
    case maps:keys(maps:with([max_depth, max_heap_words, max_host_calls], Opts)) of
        [] -> ok;
        Keys -> invalid_limits(Keys)
    end.

%% `resource_limit` and `transfer_limit` bound what a component asks of the
%% host; a core module has neither.
check_component_limits(Kind, Opts) ->
    Given = maps:with([resource_limit, transfer_limit], Opts),
    Count = fun
        (infinity) -> true;
        (N) -> is_integer(N) andalso N >= 0
    end,
    case {Kind, [Key || Key := Value <- Given, not Count(Value)]} of
        {module, _} when map_size(Given) > 0 -> unsupported_option(maps:keys(Given));
        {_, []} -> ok;
        {_, Bad} -> invalid_limits(lists:sort(Bad))
    end.

invalid_limits(Keys) ->
    wasmtime_error:new(
        link, invalid_limits, ~"limit is not a value that limit can take", #{keys => Keys}
    ).

unsupported_option(Keys) ->
    wasmtime_error:new(
        link, unsupported_option, ~"this runtime does not support the option", #{keys => Keys}
    ).

%% A component's own functions are under `""`; erlang_wasm calls that
%% interface `$root`.
root_imports(Mod, Imports) ->
    case module_kind(Mod) of
        component ->
            maps:fold(
                fun
                    ({~"$root", Name}, Fun, Acc) -> Acc#{{<<>>, Name} => Fun};
                    (Key, Fun, Acc) -> Acc#{Key => Fun}
                end,
                #{},
                Imports
            );
        module ->
            Imports
    end.

check_imports(Imports) ->
    Callable = fun
        (Fun) when is_function(Fun, 1); is_function(Fun, 2) -> true;
        ({Module, Function}) -> is_atom(Module) andalso is_atom(Function);
        (_) -> false
    end,
    case [Key || Key := Value <- Imports, not Callable(Value)] of
        [] ->
            ok;
        [Key | _] ->
            wasmtime_error:new(link, bad_import, ~"import is not callable", #{name => Key})
    end.

%% `max_memory_pages` is `memory_limit` in pages; an explicit byte limit wins.
page_limit(#{memory_limit := _} = Opts) -> Opts;
page_limit(#{max_memory_pages := infinity} = Opts) -> Opts#{memory_limit => unlimited};
page_limit(#{max_memory_pages := Pages} = Opts) -> Opts#{memory_limit => max(Pages * 65536, 1)};
page_limit(Opts) -> Opts.

%% A snapshotable instance is made from the module's instrumented form,
%% which exports its memories, globals and tables so they can be read back.
maybe_snapshotable(Mod, Imports, #{snapshotable := true} = Opts) ->
    maybe
        {ok, Prepared, Wasm, CompileOpts} ?= wasmtime_module_cache:prepared(Mod),
        {ok, Inst} ?= do_instantiate(maps:get(module, Prepared), Imports, Opts),
        {ok, Tables} ?= wasmtime_preinit:fingerprint(Inst, Prepared),
        Snap = #{
            prepared => Prepared,
            tables => Tables,
            source => crypto:hash(sha256, Wasm),
            compile => CompileOpts
        },
        {ok, Inst#instance{module = Mod, snap = Snap}}
    else
        error ->
            snapshot_error(
                invalid,
                module_not_loaded,
                ~"a snapshotable instance needs a module from load/1,2"
            );
        {error, _} = Error ->
            Error
    end;
maybe_snapshotable(Mod, Imports, Opts) ->
    do_instantiate(Mod, Imports, Opts).

snapshot_error(Class, Kind, Msg) -> snapshot_error(Class, Kind, Msg, #{}).

snapshot_error(Class, Kind, Msg, Ctx) -> wasmtime_error:new(Class, Kind, Msg, Ctx).

do_instantiate(Mod, Imports, Opts) ->
    maybe
        {ok, Wasi, #{sinks := Sinks, imports := Replaced}} ?=
            wasmtime_wasi_config:options(maps:get(wasi, Opts, none), module_kind(Mod)),
        %% an import the caller gives wins over the one an option makes
        do_instantiate(Mod, maps:merge(Replaced, Imports), Opts, Wasi, Sinks)
    end.

do_instantiate(Mod, Imports, Opts, Wasi, Sinks) ->
    Ref = make_ref(),
    Id = erlang:unique_integer([positive, monotonic]),
    StreamPid = maps:get(stream, Opts, self()),
    true = is_pid(StreamPid),
    NifOpts = (nif_options(Mod, Imports, Opts, Wasi))#{stream => stream_to(Sinks, StreamPid)},
    case wasmtime_nif:instantiate(Mod, NifOpts, Ref, Id) of
        {ok, Handle} ->
            Inst = #instance{
                handle = Handle,
                ref = Ref,
                imports = Imports,
                kind = module_kind(Mod),
                module = Mod,
                defaults = call_defaults(Opts),
                sinks = Sinks,
                stream = StreamPid,
                resource_limit = maps:get(resource_limit, Opts, infinity)
            },
            %% `timeout` bounds the start section too
            case wait_result(Inst, Id, maps:get(timeout, Opts, infinity)) of
                ok ->
                    {ok, Inst};
                {error, _} = Error ->
                    ok = destroy(Inst),
                    Error
            end;
        {error, _} = Error ->
            Error
    end.

%% Output for a sink is streamed to whoever is waiting for the call.
stream_to(Sinks, StreamPid) when map_size(Sinks) =:= 0 -> StreamPid;
stream_to(_Sinks, _StreamPid) -> caller.

%% `fuel => infinity` stays: each call then refills a metered store.
call_defaults(Opts) ->
    maps:filter(
        fun
            (timeout, V) -> V =/= infinity;
            (fuel, _) -> true
        end,
        maps:with([timeout, fuel], Opts)
    ).

%% The map the NIF reads by key; see parse_options in c_src/nif_instantiate.c.
nif_options(Mod, Imports, Opts, Wasi) ->
    HostTimeout =
        case maps:get(host_timeout, Opts, ?DEFAULT_HOST_TIMEOUT) of
            infinity -> 16#FFFFFFFF;
            T when is_integer(T), T >= 0 -> T
        end,
    HostPid = maps:get(host, Opts, undefined),
    true = HostPid =:= undefined orelse is_pid(HostPid),
    InboxLimit = maps:get(inbox_limit, Opts, ?DEFAULT_INBOX_LIMIT),
    true = is_integer(InboxLimit) andalso InboxLimit > 0,
    #{
        imports => maps:keys(Imports),
        wasi => Wasi,
        memory_limit => limit(memory_limit, Opts, ?DEFAULT_MEMORY_LIMIT),
        max_tables => limit(max_tables, Opts, 100),
        max_table_elements => limit(max_table_elements, Opts, 10_000_000),
        %% a component holds several core instances (componentize-py: 16)
        max_instances => limit(max_instances, Opts, default_instances(Mod)),
        host_timeout => HostTimeout,
        host => HostPid,
        inbox_limit => InboxLimit,
        shim => stdin_shim(Mod, Wasi),
        resource_limit => component_limit(resource_limit, Opts),
        transfer_limit => component_limit(transfer_limit, Opts),
        fuel => maps:get(fuel, Opts, undefined)
    }.

%% A `stream` stdout or stderr reports itself a terminal through an
%% fd_fdstat_get in front of WASI's, which forwards other fds through a small
%% module. A full build compiles it; a runtime-only build loads the
%% precompiled copy for this platform and the module's fuel setting from
%% priv/shims (scripts/precompile-shims.escript), or `undefined` when there
%% is none.
stdin_shim(Mod, #{stdout := Out, stderr := Err}) when Out =:= stream; Err =:= stream ->
    case wasmtime:features() of
        #{compiler := true} ->
            undefined;
        _ ->
            Fuel =
                case module_options(Mod) of
                    #{fuel := true} -> "fuel";
                    _ -> "plain"
                end,
            shim_file(Fuel)
    end;
stdin_shim(_, _) ->
    undefined.

shim_file(Fuel) ->
    Key = {?MODULE, shim, Fuel},
    try
        persistent_term:get(Key)
    catch
        error:badarg ->
            Shim = read_shim(Fuel),
            persistent_term:put(Key, Shim),
            Shim
    end.

read_shim(Fuel) ->
    Priv = priv_dir(),
    Dir = filename:join(Priv, "shims"),
    case file:read_file(filename:join(Priv, "wasmtime_platform")) of
        {ok, Platform} ->
            Name = string:trim(binary_to_list(Platform)) ++ "-" ++ Fuel ++ ".cwasm",
            case file:read_file(filename:join(Dir, Name)) of
                {ok, Bin} -> Bin;
                {error, _} -> undefined
            end;
        {error, _} ->
            undefined
    end.

priv_dir() ->
    case code:priv_dir(erlang_wasmtime) of
        {error, bad_name} ->
            filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
        Dir ->
            Dir
    end.

default_instances(Mod) ->
    case module_kind(Mod) of
        component -> 100;
        module -> 10
    end.

%% -1: Wasmtime's own
component_limit(Key, Opts) ->
    case maps:get(Key, Opts, infinity) of
        infinity -> -1;
        N -> N
    end.

limit(Key, Opts, Default) ->
    case maps:get(Key, Opts, Default) of
        unlimited -> -1;
        N when is_integer(N), N > 0 -> N
    end.

bin(B) when is_binary(B) -> B;
bin(L) -> unicode:characters_to_binary(L).

%% -------------------------------------------------------------------- calls

-doc #{equiv => call(Inst, Name, Args, #{})}.
-spec call(instance(), iodata(), [value() | term()]) -> {ok, [value()] | term()} | error().
call(Inst, Name, Args) -> call(Inst, Name, Args, #{}).

-doc """
Call an exported function and wait for its results.

A core module answers `{ok, Results}`, a list. A component answers
`{ok, Value}`, one term (`undefined` without result), and names an export
inside an interface `Interface#Function`; see [components](components.md).
erlang_wasm's `call(Inst, Export, {Params, Result}, Args)` is accepted for
components, the signature being read from the component.

Host functions the guest calls run in this process, so it must be able to
receive messages until the call returns. With `timeout` the guest is
interrupted when the time is up and `{error, #{class := exhaustion, kind :=
timeout}}` is returned. erlang_wasm's `max_depth` and `max_host_calls` are
refused with `kind => invalid_limits`.
With `fuel` the call may execute that many units of fuel (about one per
instruction) before it traps with `kind := out_of_fuel`; the module must have
been compiled with `fuel => true`.

`timeout` covers guest execution and the wait for it. It cannot fire while
this process is inside one of its own host functions; `host_timeout` (an
instantiate option) is what bounds the guest there.
""".
-spec call
    (instance(), iodata(), [value() | term()], #{timeout => timeout(), fuel => non_neg_integer()}) ->
        {ok, [value()] | term()} | error();
    (instance(), iodata(), {term(), term()}, [term()]) -> {ok, term()} | error().
call(Inst, Name, {_Params, _Result}, Args) when is_list(Args) ->
    %% erlang_wasm's form: the signature is read from the component instead
    call(Inst, Name, Args, #{});
call(Inst, Name, Args, Opts) when is_list(Args), is_map(Opts) ->
    maybe
        ok ?= check_call_limits(Opts),
        do_call(Inst, iolist_to_binary(Name), Args, Opts)
    end.

%% One request for a component's `wasi:http` handler (wasmtime_http_serve).
%% Take gets each part of the response in this process, while the guest waits,
%% and answers whether to go on.
-doc false.
-spec serve_http(instance(), tuple(), fun((term()) -> boolean())) ->
    {ok, {atom(), p2 | p3, binary()}} | error().
serve_http(#instance{kind = component, imports = Imports} = Inst, Request, Take) ->
    Part = fun(_, [Part]) -> {ok, [Take(Part)]} end,
    Serving = Inst#instance{imports = Imports#{{~"$http", ~"response"} => Part}},
    do_call(Serving, {serve, Request}, [], #{});
serve_http(#instance{}, _, _) ->
    %% a core module exports no component interface
    {ok, {no_handler, p2, <<>>}}.

-doc #{equiv => call_ref(Inst, Ref, Args, #{})}.
-spec call_ref(instance(), ref(), [value()]) -> {ok, [value()]} | error().
call_ref(Inst, Ref, Args) -> call_ref(Inst, Ref, Args, #{}).

-doc """
Call a `funcref` the instance handed out (from a table, a global, a result
or a host function argument), with the options of `call/4`.
""".
-spec call_ref(instance(), ref(), [value()], #{timeout => timeout(), fuel => non_neg_integer()}) ->
    {ok, [value()]} | error().
call_ref(Inst, Ref, Args, Opts) when is_reference(Ref), is_list(Args), is_map(Opts) ->
    maybe
        ok ?= check_call_limits(Opts),
        do_call(Inst, Ref, Args, Opts)
    end.

do_call(#instance{handle = H, defaults = Defaults} = Inst, Name, Args, Opts0) ->
    Opts = maps:merge(Defaults, Opts0),
    Id = erlang:unique_integer([positive, monotonic]),
    case wasmtime_nif:call(H, Name, Args, Id, maps:get(fuel, Opts, undefined)) of
        enqueued -> wait_result(Inst, Id, maps:get(timeout, Opts, infinity));
        {error, _} = Error -> Error
    end.

-doc """
Interrupt the call running on the instance, from any process.

The call fails with `{error, #{class := trap, kind := interrupt}}` at the
guest's next loop back-edge or function entry, or at once if it is waiting
inside a host function. Returns `not_running` when the instance is idle.
""".
-spec interrupt(instance()) -> ok | not_running.
interrupt(#instance{handle = H}) -> wasmtime_nif:interrupt(H).

-doc """
Stop the instance and free its store now, rather than when the last term
referring to it is garbage collected.

A running call ends as with `interrupt/1` and its caller gets that error;
queued calls answer `kind => stopped`, and so does every call made after.
Returns once the store is freed, so a pooled instance has given its slot
back. Calling it again, or on an instance that failed to instantiate,
returns `ok`.
""".
-spec destroy(instance()) -> ok.
destroy(#instance{handle = H, ref = Ref}) ->
    Id = erlang:unique_integer([positive, monotonic]),
    case wasmtime_nif:destroy(H, Id) of
        ok ->
            ok;
        enqueued ->
            %% The worker always answers: a guest is stopped at its next
            %% epoch check, a host call or stream wait ends on the abort
            %% flag. Only a blocking read of an inherited stdin holds it.
            receive
                {wasmtime_result, Ref, Id, ok} -> ok
            after infinity -> ok
            end
    end.

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
call_async(#instance{handle = H, defaults = Defaults}, Name, Args) when is_list(Args) ->
    Id = erlang:unique_integer([positive, monotonic]),
    %% the instance's `fuel` applies; its `timeout` does not, `await/3` has its own
    case
        wasmtime_nif:call(H, iolist_to_binary(Name), Args, Id, maps:get(fuel, Defaults, undefined))
    of
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
            wait_result(Inst, Id, Timeout);
        {wasmtime_stream, Ref, Which, Bytes} when map_size(Inst#instance.sinks) > 0 ->
            ok = streamed(Inst, Which, Bytes),
            wait_result(Inst, Id, Timeout)
    after Timeout ->
        %% cancel/2 ends request Id and drops its result. `not_running` means
        %% it had already finished: the result is in the mailbox, so it is
        %% the answer after all.
        case wasmtime_nif:cancel(H, Id) of
            ok ->
                settle(Inst, Id),
                timeout_error(Timeout);
            not_running ->
                receive
                    {wasmtime_result, Ref, Id, Result} -> Result
                after 0 -> timeout_error(Timeout)
                end
        end
    end.

%% Bytes of an instance with sinks: to the sink, or else on to the `stream`
%% process they were meant for.
streamed(#instance{sinks = Sinks}, Which, Bytes) when is_map_key(Which, Sinks) ->
    wasmtime_wasi_config:deliver(Sinks, Which, Bytes);
streamed(#instance{ref = Ref, stream = Stream}, Which, Bytes) ->
    Stream ! {wasmtime_stream, Ref, Which, Bytes},
    ok.

timeout_error(Timeout) ->
    wasmtime_error:new(exhaustion, timeout, ~"call timed out", #{timeout => Timeout}).

%% After a cancel no result message follows, but a host call sent before the
%% cancel may still be queued; answer it so nothing lingers.
settle(#instance{handle = H, ref = Ref} = Inst, Id) ->
    receive
        {wasmtime_result, Ref, Id, _} ->
            ok;
        {wasmtime_host_call, Ref, HostId, _, _} ->
            _ = wasmtime_nif:host_reply(H, HostId, host_error(#{reason => interrupted})),
            settle(Inst, Id);
        {wasmtime_stream, Ref, Which, Bytes} when map_size(Inst#instance.sinks) > 0 ->
            ok = streamed(Inst, Which, Bytes),
            settle(Inst, Id)
    after 0 -> ok
    end.

%% A host fun answers {ok, [Results]}, {trap, Reason} or {error, Reason}, for
%% a core import and for a component import alike (zero or one result there),
%% as in erlang_wasm. A component import may also be an arity-1 fun,
%% erlang_wasm's typed form (import_fun/2): it returns the value bare and
%% raises to trap. The NIF reads {ok, Results} for a core import, {ok, Value}
%% for a component one, and {error, Map}, the error the call answers with.
%% The guest dropped a host resource and the import map has no fun for it:
%% the entry goes (wasmtime_component, c_src/nif_component.c).
run_host(Imports, {_, <<"[resource-drop]", _/binary>>} = Key, _Inst, [Handle]) when
    not is_map_key(Key, Imports)
->
    ok = wasmtime_component:host_drop(Handle),
    {ok, undefined};
run_host(Imports, Key, #instance{kind = Kind} = Inst, Args) ->
    _ = Kind =:= component andalso wasmtime_component:host_limit(Inst#instance.resource_limit),
    try apply_host(maps:get(Key, Imports), Kind, #{instance => Inst}, Args) of
        {typed, Value} ->
            {ok, Value};
        {ok, [Value]} when Kind =:= component -> {ok, Value};
        {ok, []} when Kind =:= component -> {ok, undefined};
        {ok, Results} when Kind =:= module, is_list(Results) -> {ok, Results};
        {Failed, Reason} when Failed =:= trap; Failed =:= error ->
            host_error(#{host => Key, reason => Reason});
        Other ->
            host_error(#{host => Key, reason => {bad_return, Other}})
    catch
        %% a wasmtime_error constructor in the fun: the call answers with it
        throw:{wasmtime_error, Error} ->
            {error, Error};
        Class:Reason:Stack ->
            host_error(#{host => Key, reason => Reason, class => Class, stacktrace => Stack})
    end.

apply_host({Module, Function}, _Kind, Context, Args) ->
    Module:Function(Context, Args);
apply_host(Fun, component, _Context, Args) when is_function(Fun, 1) ->
    {typed, Fun(Args)};
apply_host(Fun, _Kind, Context, Args) ->
    Fun(Context, Args).

host_error(Ctx) ->
    wasmtime_error:new(trap, host_error, ~"host error", Ctx).

-doc #{equiv => snapshot(Inst, #{})}.
-spec snapshot(instance()) -> {ok, snapshot()} | error().
snapshot(Inst) -> snapshot(Inst, #{}).

-doc """
Capture an initialized instance, so later ones start where it is now, as
erlang_wasm's `wasm:snapshot/1,2`.

```erlang
{ok, Mod} = wasmtime:load(Bytes),
{ok, Init} = wasmtime:instantiate(Mod, Imports, #{snapshotable => true}),
{ok, _} = wasmtime:call(Init, ~"init", []),
{ok, Image} = wasmtime:snapshot(Init),
ok = wasmtime:destroy(Init),

{ok, Fresh} = wasmtime:restore(Image, Imports, #{}),
{ok, _} = wasmtime:call(Fresh, ~"handle", []).
```

The image is a module compiled to start in the captured state: memories and
mutable globals. Taking it costs a compile; restoring from it is an
ordinary instantiation. `Opts` takes a `version`, given back by
`snapshot_info/1`, and a `compatibility_key` that `restore/3` must repeat.

Refused: an instance made without `snapshotable => true` (`kind =>
not_snapshotable`), one with a call running (`busy`), a component, and what
`preinit/3` refuses: imported memories, tables or globals, GC types, a table
changed since the instance was made (`class => preinit`). See
[snapshots](snapshots.md).
""".
-spec snapshot(instance(), #{version => term(), compatibility_key => term()}) ->
    {ok, snapshot()} | error().
snapshot(#instance{snap = undefined}, Opts) when is_map(Opts) ->
    snapshot_error(
        invalid, not_snapshotable, ~"instantiate with `snapshotable => true` to capture"
    );
snapshot(#instance{snap = Snap} = Inst, Opts) when is_map(Opts) ->
    #{prepared := Prepared, tables := Tables, source := Source, compile := CompileOpts} = Snap,
    maybe
        {ok, Wasm} ?= idle(wasmtime_preinit:capture(Inst, Prepared, Tables, CompileOpts)),
        {ok, Mod} ?= compile(Wasm, CompileOpts),
        {ok, #snapshot{
            module = Mod,
            wasm = Wasm,
            source = Source,
            version = maps:get(version, Opts, undefined),
            key = maps:get(compatibility_key, Opts, undefined)
        }}
    end.

%% erlang_wasm's kind for a capture refused because a call is running
idle({error, #{kind := instance_busy} = Error}) -> {error, Error#{kind := busy}};
idle(Result) -> Result.

-doc """
Make a fresh instance at a captured point, as erlang_wasm's `wasm:restore/3`.

The imports are yours to give again: the image carries the guest's state,
not what the host held for it. The module's start section does not run; it
ran before the capture. `Opts` are `instantiate/3`'s, plus the
`compatibility_key` the image was captured with, when it had one
(`kind => snapshot_incompatible` otherwise).
""".
-spec restore(snapshot(), imports(), options()) -> {ok, instance()} | error().
restore(#snapshot{key = Key}, _Imports, #{compatibility_key := Other}) when Other =/= Key ->
    snapshot_error(
        invalid, snapshot_incompatible, ~"the image was captured with another compatibility key"
    );
restore(#snapshot{key = Key}, _Imports, Opts) when
    Key =/= undefined, not is_map_key(compatibility_key, Opts)
->
    snapshot_error(
        invalid, snapshot_incompatible, ~"the image was captured with a compatibility key"
    );
restore(#snapshot{}, _Imports, #{snapshotable := true}) ->
    snapshot_error(
        invalid, not_snapshotable, ~"an instance restored from an image cannot be captured again"
    );
restore(#snapshot{module = Mod}, Imports, Opts) when is_map(Imports), is_map(Opts) ->
    instantiate(Mod, Imports, Opts).

-doc "What an image holds: `bytes` (its module's size), `module` and `version`.".
-spec snapshot_info(snapshot()) ->
    #{bytes := non_neg_integer(), module := module_ref(), version := term()}.
snapshot_info(#snapshot{module = Mod, wasm = Wasm, version = Version}) ->
    #{bytes => byte_size(Wasm), module => Mod, version => Version}.

-doc """
Write an image to a file, so a later node need not run the initialization
again. Written to a temporary name and renamed, so a reader never sees half
a file. The directory is as trusted as your release: whoever can write the
file chooses what a restored instance starts with.
""".
-spec save_snapshot(snapshot(), file:name_all()) -> ok | error().
save_snapshot(#snapshot{wasm = Wasm, source = Source, version = Version, key = Key}, Path) ->
    Bin = term_to_binary({wasmtime_snapshot, 1, Source, Version, Key, Wasm}, [{compressed, 1}]),
    Tmp = [Path, ".tmp-", integer_to_list(erlang:unique_integer([positive]))],
    maybe
        ok ?= file:write_file(Tmp, Bin),
        ok ?= file:rename(Tmp, Path)
    else
        {error, Reason} ->
            _ = file:delete(Tmp),
            snapshot_error(link, snapshot_not_written, ~"cannot write the snapshot", #{
                path => Path, reason => Reason
            })
    end.

-doc """
Read an image back, for a module you name: one from `load/1,2` with the bytes
the image was captured from. An image of another module is refused with
`kind => snapshot_incompatible`. The image's module is compiled here, with
the options `Mod` was loaded with.
""".
-spec load_snapshot(file:name_all(), module_ref()) -> {ok, snapshot()} | error().
load_snapshot(Path, Mod) ->
    maybe
        {ok, Bin} ?= file:read_file(Path),
        {ok, Bytes, CompileOpts} ?= wasmtime_module_cache:source(Mod),
        {wasmtime_snapshot, 1, Source, Version, Key, Wasm} ?= decode_snapshot(Bin),
        true ?= Source =:= crypto:hash(sha256, Bytes),
        {ok, Image} ?= compile(Wasm, CompileOpts),
        {ok, #snapshot{module = Image, wasm = Wasm, source = Source, version = Version, key = Key}}
    else
        {error, #{}} = Error ->
            Error;
        {error, Reason} ->
            snapshot_error(link, snapshot_not_read, ~"cannot read the snapshot", #{
                path => Path, reason => Reason
            });
        error ->
            snapshot_error(
                invalid, module_not_loaded, ~"load_snapshot/2 needs a module from load/1,2"
            );
        false ->
            snapshot_error(
                invalid, snapshot_incompatible, ~"the image was captured from another module"
            );
        _ ->
            snapshot_error(malformed, snapshot_not_read, ~"not a snapshot file", #{path => Path})
    end.

%% Decoded with `safe`: a file cannot create atoms or funs. What it holds is
%% checked by shape here and compiled, so validated, by Wasmtime.
decode_snapshot(Bin) ->
    try binary_to_term(Bin, [safe]) of
        {wasmtime_snapshot, 1, Source, _Version, _Key, Wasm} = Term when
            is_binary(Source), is_binary(Wasm)
        ->
            Term;
        _ ->
            invalid
    catch
        error:badarg -> invalid
    end.

-doc """
Keep an image alive, as erlang_wasm's `wasm:acquire/1`. Nothing to do here:
an image lives as long as a process holds the term. `acquire/1` and
`release/1` answer `ok` so code written for erlang_wasm runs unchanged.
""".
-spec acquire(snapshot()) -> ok.
acquire(#snapshot{}) -> ok.

-doc #{equiv => acquire(Snapshot)}.
-spec release(snapshot()) -> ok.
release(#snapshot{}) -> ok.

-doc """
Keep a reference alive, as erlang_wasm's `wasm:pin/2`. Nothing to do here:
a `ref()` term keeps its object alive for as long as the term exists.
`pin/2`, `release/2` and `release_all/1` answer `ok` so code written for
erlang_wasm runs unchanged.
""".
-spec pin(instance(), term()) -> ok.
pin(#instance{}, _Ref) -> ok.

-doc #{equiv => pin(Inst, Ref)}.
-spec release(instance(), term()) -> ok.
release(#instance{}, _Ref) -> ok.

-doc #{equiv => pin(Inst, Ref)}.
-spec release_all(instance()) -> ok.
release_all(#instance{}) -> ok.

-doc """
Render an error on one line, for your logs and test failures. Takes the map
or the whole `{error, Map}`.

```erlang
{error, E} = wasmtime:call(Inst, ~"run", []),
logger:error("~ts", [wasmtime:format_error(E)]).
%% trap: unreachable (unreachable) in run
```
""".
-spec format_error(error() | wasmtime_error:error()) -> iolist().
format_error({error, Error}) -> format_error(Error);
format_error(Error) -> wasmtime_error:format(Error).

%% ------------------------------------------------------------------- memory

-doc """
Read an exported global, as erlang_wasm's `wasm:get_global/2`: the value comes
in a list, like a call result. A reference-typed global gives a `ref()`,
`null` or `{i31, N}`.
""".
-spec get_global(instance(), iodata()) -> {ok, [value()]} | error().
get_global(#instance{handle = H}, Name) ->
    case wasmtime_nif:global_get(H, Name) of
        {ok, Value} -> {ok, [Value]};
        {error, _} = Error -> Error
    end.

-doc "Deprecated: use `get_global/2`. Answers the bare value, `{ok, Value}`.".
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
table_grow(Inst, Name, Delta) -> table_grow(Inst, Name, Delta, null).

-doc "Grow an exported table by `Delta` elements holding `Init`; returns the previous size.".
-spec table_grow(instance(), iodata(), non_neg_integer(), value()) ->
    {ok, non_neg_integer()} | error().
table_grow(#instance{handle = H}, Name, Delta, Init) ->
    wasmtime_nif:table_grow(H, Name, Delta, Init).

-doc "Read an element of an exported table: a `ref()` or `null`.".
-spec table_get(instance(), iodata(), non_neg_integer()) -> {ok, value()} | error().
table_get(#instance{handle = H}, Name, Index) -> wasmtime_nif:table_get(H, Name, Index).

-doc "Write an element of an exported table: a `ref()` of the table's type, or `null`.".
-spec table_set(instance(), iodata(), non_neg_integer(), value()) -> ok | error().
table_set(#instance{handle = H}, Name, Index, Value) ->
    wasmtime_nif:table_set(H, Name, Index, Value).

-doc """
What a reference is: `#{kind => externref | funcref | struct | array | anyref,
instance => Ref}` where `instance` is the `ref/1` of the instance it belongs to.
""".
-spec ref_info(ref()) ->
    #{kind := externref | funcref | struct | array | anyref, instance := reference()}.
ref_info(Ref) -> wasmtime_nif:ref_info(Ref).

-doc """
Wrap an Erlang term as an `externref` the guest can hold and hand back.

The term is copied; `externref_data/1` copies it out again. The object lives
while any `ref()` to it or the guest reaches it. Fails with
`kind => gc_heap_full` when Wasmtime cannot allocate; `gc/1` may make room.
""".
-spec externref(instance(), term()) -> {ok, ref()} | error().
externref(#instance{handle = H}, Term) -> wasmtime_nif:externref(H, Term).

-doc "The term an `externref/2` reference wraps.".
-spec externref_data(ref()) -> {ok, term()} | error().
externref_data(Ref) -> wasmtime_nif:externref_data(Ref).

-doc "Read field `Index` of a struct the guest created.".
-spec struct_get(ref(), non_neg_integer()) -> {ok, value()} | error().
struct_get(Ref, Index) -> wasmtime_nif:struct_get(Ref, Index).

-doc "Write field `Index` of a struct; `i8` and `i16` fields take integers.".
-spec struct_set(ref(), non_neg_integer(), value()) -> ok | error().
struct_set(Ref, Index, Value) -> wasmtime_nif:struct_set(Ref, Index, Value).

-doc "The length of an array the guest created.".
-spec array_len(ref()) -> {ok, non_neg_integer()} | error().
array_len(Ref) -> wasmtime_nif:array_len(Ref).

-doc "Read element `Index` of an array.".
-spec array_get(ref(), non_neg_integer()) -> {ok, value()} | error().
array_get(Ref, Index) -> wasmtime_nif:array_get(Ref, Index).

-doc "Write element `Index` of an array.".
-spec array_set(ref(), non_neg_integer(), value()) -> ok | error().
array_set(Ref, Index, Value) -> wasmtime_nif:array_set(Ref, Index, Value).

-doc """
Run the instance's garbage collector now. Objects no longer reachable from
the guest or from a `ref()` are reclaimed and `externref/2` terms released.
Fails with `kind => busy` while the guest runs.
""".
-spec gc(instance()) -> ok | error().
gc(#instance{handle = H}) -> wasmtime_nif:gc(H).

-doc "Fuel left after the last call, for a module compiled with `fuel => true`.".
-spec fuel_remaining(instance()) -> {ok, non_neg_integer()} | error().
fuel_remaining(#instance{handle = H}) -> wasmtime_nif:fuel_remaining(H).

-doc """
The reference carried by every message this instance sends:
`{wasmtime_stream, Ref, Kind, Bytes}` and `{wasmtime_host_call, Ref, ...}`.
A process serving several instances matches on it.
""".
-spec ref(instance()) -> reference().
ref(#instance{ref = Ref}) -> Ref.

-doc """
Queue one message for the guest.

The guest reads it through `stdin => stream` (as bytes, without message
boundaries) or the `erlang.recv` import (one whole message). Never blocks:
once `inbox_limit` bytes (default 16 MB) are queued and unread it returns
`{error, #{kind := inbox_full}}` and the sender retries later. After
`close/1` it returns `{error, #{kind := closed}}`.
""".
-spec send(instance(), iodata()) -> ok | error().
send(#instance{handle = H}, Bytes) -> wasmtime_nif:send(H, Bytes).

-doc """
End the guest's input. What is queued is still delivered; after that stdin
reads return end of file and `erlang.recv` returns -1. Idempotent.
""".
-spec close(instance()) -> ok.
close(#instance{handle = H}) -> wasmtime_nif:close(H).

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

Works while the instance is idle or while a host function runs: the memory
functions also take the context a host function receives. Fails with
`kind => instance_busy` if the guest is executing.
""".
-spec read_memory(instance() | host_context(), non_neg_integer(), non_neg_integer()) ->
    {ok, binary()} | error().
read_memory(Inst, Ptr, Len) -> read_memory(Inst, default, Ptr, Len).

-doc "Same as `read_memory/3` on the exported memory called `Name`.".
-spec read_memory(
    instance() | host_context(), default | iodata(), non_neg_integer(), non_neg_integer()
) -> {ok, binary()} | error().
read_memory(Inst, Name, Ptr, Len) -> wasmtime_nif:read_memory(handle_of(Inst), Name, Ptr, Len).

handle_of(#instance{handle = H}) -> H;
handle_of(#{instance := #instance{handle = H}}) -> H.

-doc "Write `Data` at `Ptr` in the default memory. Same rules as `read_memory/3`.".
-spec write_memory(instance() | host_context(), non_neg_integer(), iodata()) -> ok | error().
write_memory(Inst, Ptr, Data) -> write_memory(Inst, default, Ptr, Data).

-doc "Same as `write_memory/3` on the exported memory called `Name`.".
-spec write_memory(
    instance() | host_context(), default | iodata(), non_neg_integer(), iodata()
) -> ok | error().
write_memory(Inst, Name, Ptr, Data) ->
    wasmtime_nif:write_memory(handle_of(Inst), Name, Ptr, Data).

-doc "Size of the default memory in pages.".
-spec memory_size(instance() | host_context()) -> {ok, non_neg_integer()} | error().
memory_size(Inst) -> memory_size(Inst, default).

-doc "Size of the exported memory called `Name` in pages.".
-spec memory_size(instance() | host_context(), default | iodata()) ->
    {ok, non_neg_integer()} | error().
memory_size(Inst, Name) ->
    case wasmtime_nif:memory_size(handle_of(Inst), Name) of
        {ok, {Pages, _Bytes}} -> {ok, Pages};
        {error, _} = Error -> Error
    end.

-doc "What the linked Wasmtime library can do; see `t:features/0`.".
-spec features() -> features().
features() -> wasmtime_nif:features().

-doc "Version of the linked Wasmtime library.".
-spec version() -> binary().
version() -> wasmtime_nif:version().
