# Precompiled modules

`serialize/1` turns a compiled module into Wasmtime's precompiled form, and
`deserialize/1` loads that form without compiling. You need it when compile
time matters at start-up (the 30 MB CPython module takes about 350 ms to
compile and 4 ms to deserialize from its 17 MB precompiled form) or when the
machine that runs modules should not carry the compiler at all.

## Compile once, at build time

```erlang
{ok, Bin} = file:read_file("python.wasm"),
{ok, Mod} = wasmtime:compile(Bin),
{ok, Pre} = wasmtime:serialize(Mod),
ok = file:write_file("python.cwasm", Pre).
```

## Load at run time

```erlang
{ok, Pre} = file:read_file("python.cwasm"),
{ok, Mod} = wasmtime:deserialize(Pre),
{ok, Inst} = wasmtime:instantiate(Mod, ...).
```

The module behaves exactly like one from `compile/1`: same exports, same
options, same instances.

## Keep a cache

```erlang
load(WasmPath) ->
    Cache = WasmPath ++ ".cwasm",
    case file:read_file(Cache) of
        {ok, Pre} ->
            case wasmtime:deserialize(Pre) of
                {ok, Mod} -> {ok, Mod};
                {error, _} -> compile_and_cache(WasmPath, Cache)
            end;
        _ ->
            compile_and_cache(WasmPath, Cache)
    end.

compile_and_cache(WasmPath, Cache) ->
    {ok, Bin} = file:read_file(WasmPath),
    {ok, Mod} = wasmtime:compile(Bin),
    {ok, Pre} = wasmtime:serialize(Mod),
    ok = file:write_file(Cache, Pre),
    {ok, Mod}.
```

A stale cache (other Wasmtime version, other CPU features) fails
`deserialize/1` with `class => compile` and falls through to a fresh compile.

## Notes

- The precompiled form is tied to the Wasmtime version in
  `scripts/wasmtime.version` and to the CPU features of the machine that
  produced it. Wasmtime checks both and refuses a mismatch.
- It contains machine code. Wasmtime verifies the header, not the code, so
  `deserialize/1` must only ever see bytes that came from `serialize/1` on a
  machine you trust. Never deserialize input from a user; give users `.wasm`
  files and `compile/1`, which validates everything.
- The bytes are not a WebAssembly module: `compile/1` rejects them, and
  `deserialize/1` rejects a `.wasm` file.
- A node that only ever loads precompiled modules can be built without the
  compiler: `WASMTIME_RUNTIME_ONLY=1 rebar3 compile`, 4 MB instead of 25.
  See [building](building.md), "Runtime-only builds".
