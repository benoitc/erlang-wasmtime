# Components

A component is a WebAssembly module with a typed interface: its imports and
exports are WIT functions taking strings, records, lists, variants and
resources, not just numbers. You need it for guests built as components
(`cargo component`, `wasm32-wasip2` Rust programs, componentize-py, jco) and
for WASI 0.2. The same functions as for core modules load, instantiate and
call them; values cross as Erlang terms, with the mapping erlang_wasm uses,
so a component gives the same answers on both runtimes.

## Load and call

```erlang
{ok, Bin} = file:read_file("guest.component.wasm"),
{ok, Mod} = wasmtime:compile(Bin),          % a component is detected
component = wasmtime:module_kind(Mod),
{ok, Inst} = wasmtime:instantiate(Mod),
{ok, 42} = wasmtime:call(Inst, ~"add", [2, 40]).
```

`call/3` returns `{ok, Value}` (one value, `undefined` for a function
without result), not the list a core function returns.

An export inside an interface is named `Interface#Function`, as erlang_wasm
names it; the version may be left out when the component exports one:

```erlang
{ok, H} = wasmtime:call(Inst, ~"example:counter/counters#make-counter", [0]),
{ok, 1} = wasmtime:call(Inst, ~"example:counter/counters#[method]counter.increment", [H, 1]).
```

`exports/1` and `imports/1` list interfaces as `{Name, instance}` and each
function as `{~"iface#func", func}`, the name `call/3` takes.
erlang_wasm's `call(Inst, Export, {Params, Result}, Args)` is accepted too;
the signature is read from the component instead.

## How values look

| WIT | Erlang |
|---|---|
| `bool` | `true`, `false` |
| `s8` to `u64` | integer, range-checked |
| `f32`, `f64` | float, or `nan`, `infinity`, `neg_infinity` |
| `char` | integer code point |
| `string` | UTF-8 binary |
| `list<u8>` | binary |
| `list<T>` | list |
| `record` | map with the field names as binaries: `#{~"x" => 1}` |
| `tuple` | tuple |
| `variant` | `{~"case", Payload}`, `{~"case", undefined}` without payload (a bare `~"case"` is accepted) |
| `enum` | binary: `~"red"` |
| `option<T>` | `none`, `{some, V}` |
| `result<T, E>` | `{ok, V}`, `{error, E}`, `undefined` for a missing payload |
| `flags` | list of binaries, in declaration order |
| `map<K, V>` | map |
| `own<R>`, `borrow<R>` | integer handle |

A term that does not fit the type is `{error, #{kind := argument_type}}`,
with the reason in `msg`: an invalid UTF-8 string, a surrogate `char`, an
integer out of range, an unknown case or flag, a missing record field.
`stream`, `future` and `error-context` cannot cross: see "Async exports and
imports".

## Provide imports

Key each function by `{Interface, Function}`, with or without the
interface's version, and answer as for a core import, with a list of zero
or one result:

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{
    {~"example:host/clock", ~"now"} => fun(_Inst, []) -> {ok, [erlang:system_time()]} end,
    {~"example:host/clock", ~"add"} => fun(_Inst, [A, B]) -> {ok, [A + B]} end}).
```

erlang_wasm's typed form works too: a one-argument fun gets the argument
list and returns the value itself; an exception traps the guest.

```erlang
Shout = wasmtime:import_fun({[string], string}, fun([S]) -> string:uppercase(S) end),
{ok, Inst} = wasmtime:instantiate(Mod, #{{~"example:agg/host", ~"shout"} => Shout}).
```

A function the component imports at its root, outside any interface, is
keyed `{<<>>, Function}`. An import nobody provides is a link error at
`instantiate/2`.

## Resources

A resource the guest hands out is an integer handle, valid in the instance
that made it. Pass it back to the guest's methods, and drop it when done:

```erlang
{ok, C} = wasmtime:call(Inst, ~"example:counter/counters#make-counter", [5]),
{ok, 8} = wasmtime:call(Inst, ~"example:counter/counters#[method]counter.increment", [C, 3]),
ok = wasmtime:drop_resource(Inst, C).
```

Dropping runs the guest's destructor. `destroy/1` drops every handle the
instance still holds. erlang_wasm's `drop_resource/3`, with the
destructor's export name, is accepted.

## Resources the host defines

When the component imports an interface with a `resource`, the object is
yours: the guest only holds handles. `wasmtime_component` keeps what stands
behind each handle, with erlang_wasm's functions.

```erlang
Kv = ~"example:kv/store",
Imports = #{
    {Kv, ~"[constructor]bucket"} => fun(_Inst, [Name]) ->
        {ok, [wasmtime_component:host_new(bucket, {Name, []})]}
    end,
    {Kv, ~"[method]bucket.put"} => fun(_Inst, [Handle, Item]) ->
        {ok, {bucket, {Name, Items}}} = wasmtime_component:host_get(Handle),
        ok = wasmtime_component:host_update(Handle, {Name, [Item | Items]}),
        {ok, []}
    end,
    {Kv, ~"[method]bucket.count"} => fun(_Inst, [Handle]) ->
        {ok, {bucket, {_, Items}}} = wasmtime_component:host_get(Handle),
        {ok, [length(Items)]}
    end
},
{ok, Inst} = wasmtime:instantiate(Mod, Imports, #{}).
```

A host function returns the handle where the interface says `own<bucket>`
and receives it where it says `own<bucket>` or `borrow<bucket>`. When the
guest drops its handle the entry is removed. To be told, add a fun under
`{Interface, ~"[resource-drop]bucket"}`: it gets `[Handle]` and calls
`host_drop/1` itself.

- A resource is the host's when the import map has at least one key for its
  interface.
- The table belongs to the process that serves the host calls: the caller,
  or the `host` process.
- `destroy/1` on an instance that still holds handles tells nobody. Drop
  what `host_live/0` lists, or let the process end.
- A host function that takes an owned handle back (a `close`) calls
  `host_drop/1` itself. A second drop of the same handle changes nothing.
- One component may define 32 host resources.

## WASI 0.2

With a `wasi` option the component gets WASI 0.2, configured by the same
keys as preview 1: `args`, `env`, `dirs`, `stdin`, `stdout`, `stderr`,
`clocks`. A command component runs with `run/1,2`:

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{
    args => [~"upper"], stdin => {binary, ~"make me loud"}, stdout => capture}}),
ok = wasmtime:run(Inst),
{ok, {~"MAKE ME LOUD", <<>>, {0, 0}}} = wasmtime:read_output(Inst).
```

See [WASI](wasi.md), "WASI 0.2", for streams, clocks and exit statuses.

## Async exports and imports

An `async func` export is called like any other, with `call/3,4`; the call
returns when the function has its result:

```erlang
{ok, Component} = wasmtime:compile(Bytes),
{ok, I} = wasmtime:instantiate(Component),
{ok, Sum} = wasmtime:call(I, ~"sum", [[1, 2, 3]], #{timeout => 5000}).
```

An `async func` import is a host function like the others:

```erlang
Fetch = fun(_Inst, [Url]) -> {ok, [download(Url)]} end,
{ok, I} = wasmtime:instantiate(Component, #{imports => #{{~"", ~"fetch"} => Fetch}}).
```

Notes:

- `wasmtime:features()` says whether the library can: `component_async`.
  It needs this project's patched library (see [building](building.md)).
- This is erlang_wasm's `wasm_component:call_async/4`; no type signature is
  given, the component declares it. `wasmtime:call_async/3` is something
  else, a call you collect later with `await/2`.
- A guest's host calls run one at a time: while your function runs, no other
  task of that instance moves.
- A task still running when its function returned its result moves only
  during a later call into the instance.
- A function whose result, or a host import whose argument, holds a
  `stream`, `future` or `error-context` is refused with `kind => unsupported_type`.
  erlang_wasm's `start_async/4` and `pump/2` have no counterpart.
- `timeout`, `interrupt/1` and a dead caller stop a call wherever it waits,
  in the guest, on a timer or on a socket. The instance cannot be entered
  again afterwards.

## Notes

- A component instance that trapped cannot be called again: the Component
  Model forbids entering it. Instantiate a new one.
- Core-module functions do not apply to a component instance:
  `get_global/2`, the table functions and the memory functions answer
  `kind => component` or `no_memory`.
- Precompiled components work as modules do: `serialize/1`,
  `deserialize/1,2`, `deserialize_file/1,2`.
- A component in a pool takes one slot per core instance, memory and table
  it holds. Size the pool for it: a componentize-py agent holds 16 core
  instances, 1 memory and 2 tables, so 256 live agents need
  `#{instances => 256, core_instances => 4096, memories => 256, tables => 512}`.
  `max_instances` (per store) defaults to 100 for a component.
  [Throughput](throughput.md) has the numbers.
- `preinit/3` takes core modules only. Componentize-py already
  pre-initializes the component it builds.
- WASI interfaces are linked by version. A component importing a `wasi:*`
  interface without a version, which erlang_wasm accepts, is a link error
  here; every toolchain writes the version.
