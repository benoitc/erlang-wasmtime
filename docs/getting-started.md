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
