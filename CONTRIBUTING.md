# Contributing

How to change erlang-wasmtime and keep it green. Read
[docs/design.md](docs/design.md) first for the rules a change must keep;
this page is the mechanics.

## Checks

```sh
make check          # erlfmt, clang-format, shellcheck, elvis, xref, dialyzer, all suites
make fmt            # rewrite Erlang and C in place
rebar3 ct --suite test/wasmtime_ref_SUITE --case ref_struct
```

CI runs the same list on Ubuntu (OTP 27 and 28), macOS and FreeBSD, plus
AddressSanitizer and the runtime-only build. Run the two extra ones
yourself when you touch the NIF:

```sh
# AddressSanitizer, Linux
WASMTIME_NIF_SANITIZE=address rebar3 compile
LD_PRELOAD="$(gcc -print-file-name=libasan.so)" \
ASAN_OPTIONS="detect_leaks=0:abort_on_error=1:alloc_dealloc_mismatch=0" rebar3 ct

# AddressSanitizer, macOS
WASMTIME_NIF_SANITIZE=address rebar3 compile
ASAN_RT="$(ls "$(dirname "$(xcrun -f clang)")"/../lib/clang/*/lib/darwin/libclang_rt.asan_osx_dynamic.dylib | head -1)"
DYLD_INSERT_LIBRARIES="$ASAN_RT" \
ASAN_OPTIONS="detect_leaks=0:abort_on_error=1:alloc_dealloc_mismatch=0" rebar3 ct

# Runtime-only library (no compiler): fixtures come from a full build
escript scripts/precompile-fixtures.escript test/wasmtime_runtime_only_SUITE_data /tmp/cwasm
rm -f _build/wasmtime_nif.stamp
WASMTIME_RUNTIME_ONLY=1 WASMTIME_CWASM_DIR=/tmp/cwasm rebar3 ct --suite test/wasmtime_runtime_only_SUITE
rm -f _build/wasmtime_nif.stamp && rebar3 compile   # back to the full build
```

Removing the stamp forces the NIF to rebuild against a different library.

## Add a NIF function

The order the code enforces, with one file per step:

1. **C entry point**, in the file that owns the mechanism (see the table in
   `docs/design.md`): `static ERL_NIF_TERM nif_thing(ErlNifEnv *env, int
   argc, const ERL_NIF_TERM argv[])`. Take the instance mutex through
   `with_export`, `with_ref` or `with_memory` when you touch the store;
   never from a thread that does not hold it. Return
   `mk_error_s(env, Class, Kind, Message)` for every failure; raise
   `badarg` only for terms of the wrong shape.
2. **The table** in `c_src/nif_api.c`: `{"thing", Arity, nif_thing, 0}`;
   `ERL_NIF_DIRTY_JOB_CPU_BOUND` only for work that takes milliseconds
   (compiling, serializing) and never for anything that waits.
3. **The stub** in `src/wasmtime_nif.erl`: add to `-export`, to `-nifs`,
   and a `thing(_A, _B) -> erlang:nif_error(not_loaded).` clause.
4. **The wrapper** in `src/wasmtime.erl`: `-doc`, `-spec`, defaults and
   validation live here, the NIF only checks shapes. Export it.
5. **Docs**: a row in `docs/features.md` (implemented, or refused with its
   `kind`), the guide the feature belongs to, `CHANGELOG.md`.
6. **Tests**: a case in the suite for the mechanism, named after the
   behaviour (`stream_blocked_recv_caller_dies`), asserting the error kinds,
   not only the happy path. Helpers (compiling WAT, the hand-assembled
   binaries, `needs/2` for capability skips) are in `test/wasmtime_test.erl`.

   | Suite | Covers |
   |---|---|
   | `wasmtime_SUITE` | behaviour that spans mechanisms: interruption, caller death, timeouts, error shapes |
   | `wasmtime_module_SUITE` | compile, validate, inspect, precompiled modules, engine options |
   | `wasmtime_call_SUITE` | values, traps and traces, fuel, async calls, globals and tables |
   | `wasmtime_memory_SUITE` | linear memory access, store limits, instance lifetime |
   | `wasmtime_host_SUITE` | host functions, the `host` process |
   | `wasmtime_wasi_SUITE` | WASI arguments, environment, directories, stdio |
   | `wasmtime_stream_SUITE` | the inbox, streamed stdio, the `erlang` imports, the shim files |
   | `wasmtime_ref_SUITE` | references: funcref, externref, GC values |
   | `wasmtime_runtime_only_SUITE` | the runtime-only build against precompiled fixtures |
7. `make check`, then ASan if the C changed.

## Add a value kind or a reference kind

`c_src/nif_values.c`: extend `vtype_of` (the family), `term_to_val` and
`val_to_term`; never use `wasm_valtype_kind`. Reference kinds also need a
`ref_t` kind and its unroot in `ref_dtor` (`c_src/nif_refs.c`). Add a
round trip test through a call, a host function, a global and a table.

## Add an instantiate or WASI option

`src/wasmtime.erl` `nif_options/3` or `wasi_options/1` puts it in the
options map with its default; `parse_options` or `configure_wasi` in
`c_src/nif_instantiate.c` reads it by key. Document it in the
`options()` or `wasi_options()` type and in the guide.

## Conventions

- Guest failures never raise. `{error, #{class, kind, message}}` and a
  `trace` for traps. New `kind`s are listed in `docs/features.md`.
- One OS thread per instance, requests queued, results as messages. Do not
  add a code path where a scheduler thread waits on the worker.
- Comments say why, not what. A rule that a later edit could break gets a
  comment where it is relied on and a line in `docs/design.md`.
- Docs are task-oriented: what it is, when you need it, the code, short
  notes. No hype, no "comprehensive".
- Commits and pull requests are short and have no generated-by lines.
- Anything not implemented is refused with an error and listed under
  "Deferred" in `docs/features.md` with the reason.
- Numbers (limits, timeouts, sizes) are `#define`s or `-define`s with
  their reason in `docs/design.md`.
