# Agents

Instructions for AI coding agents working on this project.

## Project overview

Wasmtime bindings for Erlang. A C NIF (`c_src/wasmtime_nif.c`) links the
Wasmtime C API statically; `src/wasmtime.erl` is the public API. Erlang only,
no Elixir layer. Requires OTP 27+, rebar3, a C compiler and `curl` (the first
build downloads the pinned Wasmtime C API release).

## Required checks

Every change must pass all of these before committing:

```bash
rebar3 fmt                  # Format Erlang (always run first)
rebar3 compile              # Builds the NIF too; warnings are errors
rebar3 lint                 # Elvis
rebar3 xref
rebar3 dialyzer
rebar3 ct                   # Both suites
clang-format --dry-run -Werror c_src/*.c
shellcheck scripts/*.sh
scripts/test-fetch.sh       # fetch-wasmtime.sh branches, offline
```

`rebar3 check` runs the Erlang ones in sequence. `make check` runs everything.

## Commands

```bash
rebar3 compile                                   # Build (downloads Wasmtime once)
rebar3 ct                                        # All Common Test suites
rebar3 ct --suite=test/wasmtime_SUITE            # One suite
rebar3 ct --suite=test/wasmtime_SUITE --case=traps
rebar3 fmt --check                               # Formatting check only
clang-format -i c_src/wasmtime_nif.c             # Format the C
rebar3 ex_doc                                    # Docs into doc/
rebar3 hex build                                 # Must stay under 8 MB
WASMTIME_C_API_DIR=/path rebar3 compile          # Use a local Wasmtime C API
WASMTIME_RUNTIME_ONLY=1 rebar3 compile           # No compiler: 4 MB shared library
WASMTIME_SOURCE_BUILD=1 rebar3 compile           # Build the C API from source
escript scripts/precompile-fixtures.escript test/wasmtime_runtime_only_SUITE_data _build/cwasm
WASMTIME_RUNTIME_ONLY=1 WASMTIME_CWASM_DIR=$PWD/_build/cwasm rebar3 ct   # runtime-only suite
WASMTIME_NIF_SANITIZE=address rebar3 compile     # ASan build of the NIF
```

## Architecture

- `c_src/wasmtime_nif.c`: one file, sections in order: atoms and errors,
  values, instance state, host calls, worker thread, resources, NIF entry
  points, load/unload. One OS thread per instance owns the Wasmtime store.
  Calls are queued and answered with `enif_send`
  (`{wasmtime_result, Ref, Id, Result}`); host functions send
  `{wasmtime_host_call, Ref, HostId, {Module, Name}, Args}` to the caller and
  wait, bounded, for `host_reply/3`. `Ref` is an Erlang reference made at
  instantiate time, never a resource term, so worker threads cannot resurrect
  a resource. Two resource types: the handle Erlang holds (its destructor
  only signals) and the instance, owned by the handle and by its detached
  worker thread. Interruption is epoch based: a ticker thread bumps the
  engine epoch every 10 ms; `cancel/2` ends one request by id and drops its
  result.
- `src/wasmtime.erl`: public API and the `receive` loop that serves host calls
  while a call runs. Normalises options into the tuples the NIF expects.
- `src/wasmtime_nif.erl`: NIF stubs and `on_load`.
- `scripts/fetch-wasmtime.sh`: resolves the C API (`WASMTIME_C_API_DIR`, a
  prebuilt archive from upstream or from this repository's releases, else a
  source build through `scripts/build-wasmtime.sh`). `scripts/build-nif.sh`
  probes the library for compiler/WAT/WASI, passes `NIF_HAVE_*` to the C,
  links statically or copies a shared library into `priv/`, and keeps a
  stamp so a variant switch relinks. `scripts/precompile-fixtures.escript`
  makes the `.cwasm` fixtures for the runtime-only suite.
  `.github/workflows/wasmtime-runtime.yml` publishes the runtime-only and
  FreeBSD archives; their checksums are pasted into `scripts/*.sha256`.
- `test/wasmtime_SUITE.erl`: behaviour of the binding (host calls, interrupts,
  isolation, WASI, lifetime).
- `test/wasmtime_api_SUITE.erl`: API coverage in the style of wasmtime-py's
  tests (values, traps, memory, imports, WASI details, precompiled modules,
  named memories, host process, async calls, stdio capture, fuel, traces,
  globals, tables).
- `test/wasmtime_runtime_only_SUITE.erl`: the binding on a build without a
  compiler, from precompiled fixtures. The other two suites skip there.

## Conventions

- Guest failures never raise. Return `{error, #{class, kind, message}}`; add a
  `kind` atom for every new failure and document it in `docs/features.md`.
- Nothing is granted by default. A new capability is opt-in through
  `instantiate/2` options and refused explicitly when absent.
- A feature that is not implemented is refused with an error, not approximated,
  and listed under "Deferred" in `docs/features.md` with the reason.
- The C stays in one file with the section order above. Take the mutex for any
  access to instance state from a scheduler thread; the worker thread releases
  it while the guest runs.
- Docs are task-oriented, second person, what/when/how/notes, no hype. No
  "comprehensive", no em dashes.
- Commits and pull requests: concise, no generated-by or co-authored-by lines,
  no test plan section.
- Bumping Wasmtime: edit `scripts/wasmtime.version`, replace every line in
  `scripts/wasmtime.sha256`, run the full checks. The C ABI changes between
  majors.
