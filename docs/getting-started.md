# Getting started

This guide takes you from a `.wasm` file to a call from Erlang. You need it the
first time you embed a module; the other guides cover host functions, WASI and
the build.

## Add the dependency

```erlang
%% rebar.config
{deps, [{erlang_wasmtime, "0.1.0"}]}.
```

Run `rebar3 compile`. The first build downloads the Wasmtime C API and builds
`priv/wasmtime_nif.so`.

## Compile a module

From a binary:

```erlang
{ok, Bin} = file:read_file("plugin.wasm"),
{ok, Mod} = wasmtime:compile(Bin).
```

From text:

```erlang
{ok, Mod} = wasmtime:compile({wat, ~"""
    (module
      (memory (export "memory") 1)
      (func (export "add") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.add))
    """}).
```

`compile/1` runs on a dirty CPU scheduler. The module is immutable: compile once,
instantiate as often as you like.

## Inspect it

```erlang
[] = wasmtime:imports(Mod),
[{~"memory", memory}, {~"add", func}] = wasmtime:exports(Mod).
```

## Instantiate and call

```erlang
{ok, Inst} = wasmtime:instantiate(Mod),
{ok, [3]}  = wasmtime:call(Inst, ~"add", [1, 2]).
```

Arguments and results follow the function's type: `i32`/`i64` as integers,
`f32`/`f64` as floats (with `nan`, `infinity`, `neg_infinity` for what an Erlang
float cannot hold), `v128` as a 16-byte binary.

## Handle failure

```erlang
{error, #{class := trap, kind := integer_division_by_zero}} =
    wasmtime:call(Inst, ~"div", [1, 0]).
```

Every error is `{error, Map}` with `class`, `kind` and `message`. The instance
survives a trap and can be called again.

## Put a time limit on a call

```erlang
{error, #{kind := timeout}} = wasmtime:call(Inst, ~"loop", [], #{timeout => 100}).
```

Or from another process while it runs:

```erlang
ok = wasmtime:interrupt(Inst).
```

## Run a call without blocking

```erlang
{ok, Ref} = wasmtime:call_async(Inst, ~"work", [Arg]),
... do something else ...
{ok, [Result]} = wasmtime:await(Inst, Ref, 5000).
```

The call runs on the instance thread while this process continues. `await`
must run in the process that started the call, because host functions are
served there, while it waits; a guest that calls the host earlier waits for
`await` (within `host_timeout`), or use a `host` process. Two async calls on
one instance run one after the other.

## Compile options

```erlang
{ok, Mod} = wasmtime:compile(Bin, #{
    opt_level => speed_and_size,
    proposals => #{simd => false, threads => false, gc => false},
    fuel => true}).
```

- `opt_level`: Cranelift's `none`, `speed` (default) or `speed_and_size`.
- `proposals`: turn WebAssembly proposals off (or on) relative to Wasmtime's
  defaults. A module that uses a disabled one is refused by `compile/2` and
  `validate/2` with `class => compile`, which is how you pin down what a
  plugin format may contain.
- `fuel`: compile with fuel metering, see below.

`module_options/1` returns what a module was compiled with. Each distinct
option set is one Wasmtime engine, created on first use (at most 32 per
VM). Of the options only `fuel` is checked when a precompiled module is
loaded (`deserialize/2`); the optimization level and disabled proposals
need nothing at load time.

## Bound a call by instructions instead of time

```erlang
{ok, Mod}  = wasmtime:compile(Bin, #{fuel => true}),
{ok, Inst} = wasmtime:instantiate(Mod),
{error, #{kind := out_of_fuel}} = wasmtime:call(Inst, ~"loop", [], #{fuel => 1000000}),
{ok, Left} = wasmtime:fuel_remaining(Inst).
```

Fuel counts instructions (about one unit each), so the same input always
stops at the same point, unlike `timeout`. It costs a few percent of speed
and must be chosen at compile time; fuel belongs to the instance and is
consumed across calls until set again.

## Read traps with their frames

```erlang
{error, #{kind := unreachable, trace := [#{func_name := ~"inner"} | _]}} =
    wasmtime:call(Inst, ~"outer", []).
```

`trace` lists the wasm frames innermost first, with the function index and
byte offset, and names when the module carries a name section.

## Globals and tables

```erlang
{ok, 7}    = wasmtime:global_get(Inst, ~"counter"),
ok         = wasmtime:global_set(Inst, ~"counter", 8),
{ok, 4}    = wasmtime:table_size(Inst, ~"handlers"),
{ok, 4}    = wasmtime:table_grow(Inst, ~"handlers", 2).
```

Numeric and `v128` globals only; a constant global refuses `global_set`.
Tables can be measured and grown (with null elements) from Erlang; their
elements are references, which stay inside the guest.

## Read and write memory

```erlang
ok = wasmtime:write_memory(Inst, 0, <<"hello">>),
{ok, <<"hello">>} = wasmtime:read_memory(Inst, 0, 5),
{ok, {Pages, Bytes}} = wasmtime:memory_size(Inst).
```

Memory is reachable while the instance is idle, or from inside a host function.
During a call it returns `{error, #{kind := busy}}`. These act on the export
named `memory` (or the first exported memory); `read_memory/4`,
`write_memory/4` and `memory_size/2` take an export name for modules with
several memories.

## Notes

- One call runs on an instance at a time. Calls from several processes are
  queued in order.
- The process that calls `wasmtime:call` must stay able to receive messages:
  host functions and results arrive there.
- Drop every reference to an instance and its thread, store and memory are
  freed by the garbage collector.
