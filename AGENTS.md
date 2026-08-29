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

`docs/design.md` is the design note: ownership, the instance state machine,
message contracts, the two value paths, precompiled compatibility, the
build pipeline and the reasons behind every number. `CONTRIBUTING.md` says
how to add a NIF function end to end and how to run the sanitizer and
runtime-only checks. The C lives in `c_src/nif_*.c`, one file per
mechanism, with `c_src/nif.h` for the shared types and prototypes; the
design note's first table says which file to open for which task.

## Conventions

- Guest failures never raise. Return `{error, #{class, kind, message}}`; add a
  `trace` for traps. New `kind`s go into `docs/features.md`.
- Anything not implemented is refused with an error and listed under
  "Deferred" in `docs/features.md` with the reason.
- Docs are task-oriented: what it is, when you need it, the code, short notes.
  No hype, no "comprehensive", no em dashes.
- Commits and pull requests are short and carry no generated-by lines.
- A rule a later edit could break gets a comment where it is relied on and a
  line in `docs/design.md`; change both in the same commit.
