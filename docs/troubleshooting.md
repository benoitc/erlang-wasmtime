# Troubleshooting

The errors you are likely to meet, what they mean and what to do. Every
guest failure is `{error, #{class, kind, message}}`; the `kind` is the key
to look up here. Build problems show up as `rebar3 compile` output.

## The NIF does not load

| Symptom | Cause | Fix |
|---|---|---|
| `wasmtime: no prebuilt library for ...; building from source` and then a missing tool | no archive for the platform, and `git`, `cmake` or `cargo` is absent | install them (https://rustup.rs) or point `WASMTIME_C_API_DIR` at a C API tree |
| `checksum mismatch for wasmtime-...tar.xz` | a corrupt or tampered download; never an unsupported platform | delete `_build/wasmtime` and retry; if it persists, compare with the upstream checksum |
| `include/ and lib/ differ` at compile time | `WASMTIME_C_API_DIR` mixes headers and a library from different builds | use one archive |
| `wasmtime_nif.so` from an older build after changing `WASMTIME_C_API_DIR` or `WASMTIME_RUNTIME_ONLY` | the stamp file says nothing changed | `rm _build/wasmtime_nif.stamp && rebar3 compile` |
| `{error, {load_failed, ...}}` on a release | `priv/` missing the `.so` or, for runtime-only builds, `libwasmtime.so`/`.dylib` next to it | ship `priv/` whole; the NIF finds the shared library through an rpath relative to itself |

## Compile and load

| `kind` or message | Meaning | Do |
|---|---|---|
| `unavailable` on `compile/1`, `{wat, _}`, `serialize/1` | a runtime-only build has no compiler | precompile on a full build, load with `deserialize/1,2`; `features/0` says what the build can do |
| `compilation settings are not compatible with the native host` | the `.cwasm` was compiled with other engine settings (fuel, opt_level, target, CPU features) | precompile on the same platform with the options you load with; `deserialize/2` with `#{fuel => true}` or the `opt_level` used; see [precompiled](precompiled.md) |
| `module was compiled with concurrency support but it is not enabled for the host` | the `.cwasm` came from a tool with different engine defaults (the Wasmtime CLI, another embedding) | compile with this library's `serialize/1`, or the flags `scripts/precompile-shims.sh` uses |
| `too_many_configurations` | more than 32 distinct compile option sets in this VM | reuse option sets; engines are never freed |
| `class => link` | an import the module needs is not in `imports` (or WASI was not granted) | check `imports/1`; give `wasi => #{}` for WASI programs |
| `unsupported_import` | the module imports a memory, table or global | only function imports can come from Erlang |
| `unsupported_type` | `exnref` in a signature, `v128` and references in one signature, or a value that cannot cross | split the function or keep the value inside the guest |

## Calls

| `kind` | Meaning | Do |
|---|---|---|
| `timeout` | the `timeout` option expired; the guest was interrupted | the instance is usable again; raise the limit or use `call_async` |
| `interrupt` | `interrupt/1` was called, or the caller died | expected |
| `out_of_fuel` | the `fuel` budget ran out | more fuel, or none |
| `fuel_disabled` | `fuel` given for a module compiled without `fuel => true` | compile with fuel |
| `busy` | memory, globals, tables or refs accessed while the guest runs | do it from a host function (the guest is parked) or when the call returns |
| `reentrant` | a host function called the instance it runs on | keep what you need (a funcref, data) and act after the call returns |
| `stopped` | the instance handle was dropped or instantiation failed | keep a reference to the instance while you use it |
| `wrong_instance` | a `ref()` used with another instance | refs belong to the instance that made them |
| `badarity`, `badarg` | wrong number of arguments, or a value that does not match the type (`null` for a non-nullable reference, a funcref where an externref is expected, `{i31, N}` out of range) | check `exports/1` |

## Host functions

| Message | Meaning | Do |
|---|---|---|
| `host function timed out` | the Erlang fun did not return within `host_timeout` (default 30 s) | keep host funs short; hand long work to another process; raise `host_timeout` |
| `host process is gone` | the `host` process died | restart it before instantiating |
| `host function returned the wrong number of values` / `a value of the wrong type` | the fun's `{ok, Results}` does not match the import's type | return exactly the declared results |
| an exception text in `message` | the fun raised; class, reason and stacktrace are in the message | the instance is still usable |

## Streams

| Symptom | Cause | Do |
|---|---|---|
| `await/3` times out on a stdin-reading program | the guest waits for input | `send/2` a line, `close/1` to end input |
| `inbox_full` | 16 MB queued and unread | wait for the guest to read, or raise `inbox_limit` |
| nothing arrives from a Python script | stdout is block-buffered | run with `-u` or `print(..., flush=True)` |
| `stdin => stream` answers `unavailable` on a runtime-only build | no `priv/shims/<platform>-*.cwasm` for the platform | run `scripts/precompile-shims.sh` on a machine with that architecture |

## Reading a trap

```erlang
{error, #{class := trap, kind := unreachable, message := Msg,
          trace := [#{func_index := 3, func_offset := 12, func_name := ~"f", module_name := undefined} | _]}}
```

`trace` is innermost first. `func_name` is `undefined` when the module has
no name section; `func_index` still identifies the function in
`wasm-objdump` or `wasm-tools print`. `message` is Wasmtime's own text and
includes the backtrace.

## When the VM crashes

A crash inside the NIF is a bug here or in Wasmtime: build with
`WASMTIME_NIF_SANITIZE=address` (see [CONTRIBUTING.md](../CONTRIBUTING.md))
and run the case that crashes. Two aborts are known and guarded against:
`wasm_valtype_kind` on GC types and an engine for a target the library
lacks; a new one is worth an issue.
