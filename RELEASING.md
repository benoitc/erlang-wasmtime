# Releasing

What to do for a release of erlang-wasmtime, and separately for a Wasmtime
version bump. You need push rights, `gh`, and a machine of each
architecture (x86_64 and aarch64) for the shims.

## Release the library

1. `CHANGELOG.md`: turn "unreleased" into the version and date.
2. `src/erlang_wasmtime.app.src`: bump `vsn`.
3. `make check` on a full build; the ASan and runtime-only recipes in
   [CONTRIBUTING.md](CONTRIBUTING.md) if the NIF changed since the last release.
4. Commit, tag `v<version>`, push the tag. CI runs on the tag.
5. `rebar3 hex publish`. The package holds `src/`, `c_src/`, `scripts/`,
   `priv/shims/` and the docs; the CI job "Hex package stays under the 8 MB
   cap" is the size check. The Wasmtime library is not in the package; it
   is downloaded at build time.

## Bump Wasmtime

The pinned version is `scripts/wasmtime.version`. Everything below is
tied to it: the upstream archives, this repo's runtime archives, the CLI
that compiles the shims, the precompiled fixtures.

1. Edit `scripts/wasmtime.version`.
2. Download the six upstream C API archives (`x86_64` and `aarch64` for
   `linux`, `musl`, `macos`) and replace their lines in
   `scripts/wasmtime.sha256`.
3. Run the runtime workflow: `gh workflow run wasmtime-runtime.yml`. It
   builds the runtime-only library on native runners for every platform
   plus the full FreeBSD library, and attaches them to the release
   `wasmtime-runtime-<version>` (assets are immutable; pass `force` to
   replace). Paste its `SHA256SUMS` into `scripts/wasmtime-runtime.sha256`
   and the FreeBSD line into `scripts/wasmtime.sha256`.
4. Pin the CLI archives (`wasmtime-<version>-aarch64-macos.tar.xz` and
   `x86_64-linux`) in `scripts/wasmtime-cli.sha256`, then run
   `scripts/precompile-shims.sh` on an aarch64 machine and on an x86_64
   machine; commit the 14 files in `priv/shims/`. The flags in the script
   must match `make_config()` in `c_src/nif_engine.c`; `shim_files_load`
   in the tests fails when they drift.
5. Check the C API for changes that matter here: `wasmtime/conf.h`
   feature macros, the `wasmtime_val_t` layout, the reference API
   (`*_unroot` signatures), `wasi.h` stdio hooks. `docs/design.md` lists
   what the code relies on.
6. `rebar3 compile && rebar3 ct` on a full build, then the runtime-only
   recipe with fresh fixtures from `scripts/precompile-fixtures.escript`.
   The runtime-only CI job proves the full and runtime builds still
   accept the same precompiled modules.
7. `CHANGELOG.md`: note the new Wasmtime version. `README.md` and
   `docs/features.md` mention the major version.
