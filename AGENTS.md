# Agents

Instructions for AI coding agents working on erlang-wasmtime. Read this file
before you change anything; it applies to every agent and every change.

## Project Overview

Wasmtime bindings for Erlang. A C NIF (`c_src/nif_*.c`) links the Wasmtime C
API statically; `src/wasmtime.erl` is the public API. Erlang only, no Elixir
layer, no Erlang dependencies. Requires Erlang/OTP 27 or later, rebar3, a C
compiler and `curl` (the first build downloads the pinned Wasmtime C API
release).

## First principle: the guest never takes the node down

The NIF runs in the VM's address space and the guest is untrusted. Every
change to the C, to option validation or to how a value crosses must keep
three things true before it is called done, committed or opened as a pull
request:

1. **Guest failures are terms.** Nothing a guest does raises or aborts:
   `{error, #{class, kind, message}}`, with a `trace` for traps. A test shows
   the error path, not only the happy one.
2. **No call that aborts.** Several Wasmtime C API calls abort the process on
   input they do not support (`wasm_valtype_kind` on GC types, an engine
   configuration it cannot build, bad UTF-8 in a component value). Check a new
   call for the same and validate before it; `docs/design.md`, "What can
   still stop the node", lists the known ones.
3. **Schedulers never wait.** One OS thread per instance, requests queued,
   results as messages. Do not add a path where a scheduler thread waits on
   the worker, and do not block in a destructor.

Read `docs/design.md` before changing the C: it holds the ownership rules and
the instance state machine these depend on. When you change a rule, change
that page in the same commit.

## Required Checks

Every change must be formatted and pass all checks before committing. This
list matches what CI gates on; see [CONTRIBUTING.md](CONTRIBUTING.md) for the
rest of the workflow.

```bash
rebar3 fmt                  # Auto-format Erlang (always run first)
rebar3 compile              # Builds the NIF too; warnings are errors
rebar3 ct                   # All suites
rebar3 fmt --check          # CI fails on unformatted code
rebar3 lint                 # Elvis linter must pass
rebar3 dialyzer             # Type checking must pass
rebar3 xref                 # Cross-reference analysis must pass
rebar3 ex_doc               # Docs must build
clang-format --dry-run -Werror c_src/*.c c_src/*.h
shellcheck scripts/*.sh
scripts/test-fetch.sh       # fetch-wasmtime.sh branches, offline
```

`rebar3 check` runs the Erlang ones in sequence. `make check` runs everything
except `ex_doc`. When the C changed, also run the AddressSanitizer and
runtime-only recipes in [CONTRIBUTING.md](CONTRIBUTING.md).

## Pull Requests

Work on one issue goes in one pull request. Give each change a reviewer has
to look at its own commit, with its tests, rather than opening a pull request
per change. Docs and CHANGELOG entries go in the same pull request.

- Every bug fix and feature has a test. Show it failing on main.
- Never relax a limit or a check to make a guest pass; exclude the legitimate
  case precisely.
- Descriptions state what was wrong, the fix in a few lines, and breaking
  changes. Reference issues with `Fixes #N`. No test plan, no file-by-file
  walkthrough.
- No `Co-Authored-By`, "Generated with" or similar trailers, in commits or
  pull requests.
- CHANGELOG: plain English, what was wrong or what is new and what it means
  for the user. No implementation details.
- Plain English, no inflated wording, no "comprehensive", no em dashes, and a
  person has read the change before it is opened.

## Build & Development Commands

```bash
rebar3 compile                                   # Build (downloads Wasmtime once)
rebar3 ct                                        # All Common Test suites
rebar3 ct --suite=test/wasmtime_SUITE            # One suite
rebar3 ct --suite=test/wasmtime_SUITE --case=traps
rebar3 lint                                      # Elvis linter
rebar3 fmt --check                               # Check formatting (erlfmt)
rebar3 fmt                                       # Auto-format Erlang
clang-format -i c_src/*.c c_src/*.h              # Format the C
rebar3 dialyzer                                  # Type checking
rebar3 xref                                      # Cross-reference analysis
rebar3 ex_doc                                    # Docs into doc/
rebar3 hex build                                 # Must stay under 8 MB
WASMTIME_C_API_DIR=/path rebar3 compile          # Use a local Wasmtime C API
WASMTIME_RUNTIME_ONLY=1 rebar3 compile           # No compiler: 4 MB shared library
WASMTIME_SOURCE_BUILD=1 rebar3 compile           # Build the C API from source
escript scripts/precompile-fixtures.escript test/wasmtime_runtime_only_SUITE_data _build/cwasm
WASMTIME_RUNTIME_ONLY=1 WASMTIME_CWASM_DIR=$PWD/_build/cwasm rebar3 ct   # runtime-only suite
WASMTIME_NIF_SANITIZE=address rebar3 compile     # ASan build of the NIF
WASI_SDK=/path scripts/build-py-reactor.sh       # CPython reactor for the bench, once
scripts/bench-reactor.sh                         # pre-initialized CPython benchmark
scripts/build-component-fixtures.sh              # rebuild test components from source (wasm32-wasip2)
```

## Architecture

### Module Layers

**Public API:** `src/wasmtime.erl` (the whole API: defaults, option validation, waiting for results, serving host calls in the caller)

**Erlang support:** `src/wasmtime_options.erl` (compile options to the engine key the NIF reads), `src/wasmtime_limits.erl` (limit presets, erlang_wasm's `wasm_limits` API), `src/wasmtime_component.erl` (the table behind host resource handles, erlang_wasm's `wasm_component` host functions), `src/wasmtime_script_worker.erl` (requests through an adapter: runner, deadline, request directory), `src/wasmtime_worker_adapter.erl` (the adapter behaviour), `src/wasmtime_script_v1.erl` (the script protocol), `src/wasmtime_javascript_command.erl` and `src/wasmtime_python_command.erl` (the shipped adapters), `src/wasmtime_worker_error.erl`, `src/wasmtime_instance_worker.erl` (one instance in a process, erlang_wasm's `wasm_instance_worker` API), `src/wasmtime_preinit.erl` (pre-initialization: parse, instrument and rewrite a module), `src/wasmtime_nif.erl` (the NIF stub table, nothing else), `src/wasmtime_module_cache.erl` (the node's cache of compiled modules, the only process; `wasmtime_app` and `wasmtime_sup` start it)

**Instance lifetime (C):** `nif_instance.c` (request queue, worker thread, destructors), `nif_instantiate.c` (options, WASI, import binding, the linker cache), `nif_call.c` (calling the guest)

**Values (C):** `nif_values.c` (numbers, v128, references), `nif_refs.c` (the `ref()` resource, GC objects), `nif_cvalues.c` (component values, the resource table)

**Mechanisms (C):** `nif_host.c` (host functions), `nif_stream.c` (inbox, streamed stdio, the `erlang` imports), `nif_component.c` (components, WASI 0.2), `nif_clock.c` (`clocks => monotonic` for preview 1), `nif_preinit.c` (what a snapshot reads), `nif_engine.c` (engines, the pooling allocator, the shim)

**Other (C):** `nif_api.c` (entry points not owned by another file, the function table, load and unload), `nif_atoms.c` (atoms and error terms), `nif_os.c` (OS calls kept apart from `nif.h`)

### Key Files

- `c_src/nif.h`: every struct and the prototypes shared between the C files
- `docs/design.md`: ownership, the instance state machine, message contracts, the two value paths, precompiled compatibility, the build pipeline and the reason behind every number; its first table says which file to open for which task
- `docs/features.md`: what is implemented, refused and deferred, with the error kinds
- `CONTRIBUTING.md`: how to add a NIF function end to end, the sanitizer and runtime-only checks
- `RELEASING.md`: a release, and a Wasmtime version bump
- `scripts/`: the Wasmtime download and build (`fetch-wasmtime.sh`, `build-nif.sh`), the pinned version and checksums

### Execution Model

Each instance owns one OS thread and one Wasmtime store. A call is queued,
runs on that thread, and its result comes back as a message; the calling
process waits in `receive`, never inside a NIF. A host function runs in the
calling process, or in the `host` process. Core modules and components run
the same way.

### Test Organization

- `test/wasmtime_*_SUITE.erl`: Common Test suites, one per mechanism; the
  table in [CONTRIBUTING.md](CONTRIBUTING.md) says which covers what
- `test/wasmtime_test.erl`: shared helpers (compiling WAT, hand-assembled
  binaries, `needs/2` for capability skips)
- `test/fixtures/components`: sources of the test components, rebuilt with
  `scripts/build-component-fixtures.sh`
- `test/wasmtime_runtime_only_SUITE.erl` runs against precompiled fixtures
  on a build without the compiler
- Name a case after the behaviour and assert the error kinds, not only the
  happy path

## Conventions

- New error `kind`s go into `docs/features.md`.
- Anything not implemented is refused with an error and listed under
  "Deferred" in `docs/features.md` with the reason.
- Docs are task-oriented: what it is, when you need it, the code, short
  notes.
- A rule a later edit could break gets a comment where it is relied on and a
  line in `docs/design.md`; change both in the same commit.
- Numbers (limits, timeouts, sizes) are `#define`s or `-define`s with their
  reason in `docs/design.md`.

## Linting Notes

Elvis rules are configured in `elvis.config`, the only lint configuration.
`rebar3 lint` reads that file and ignores any `{elvis, ...}` entry in
`rebar.config` while it exists, so an exemption added to `rebar.config` has
no effect. A module that outgrows a size rule is added to that rule's
`ignore` list with its reason; the limit itself is not raised. Notable
exceptions:

- `wasmtime` and `wasmtime_nif` are excluded from `no_god_modules`: one is
  the whole public API, the other its stub table
- `wasmtime` and `wasmtime_preinit` are excluded from `max_module_length`
- `dont_repeat_yourself` has `min_complexity => 12` for the two receive
  clauses of `await/3`
- Atom naming regex: `^[a-z](_?[a-zA-Z0-9]+)*(_SUITE)?$`
- erlfmt covers `src`, `test`, `examples`, `bench`, the escripts in
  `scripts`, `rebar.config` and `elvis.config`, at the default width (100)
