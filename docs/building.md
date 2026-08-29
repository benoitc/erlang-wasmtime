# Building and shipping

How the NIF gets its Wasmtime library, and what to do when the default does not
fit: offline builds, a system-installed Wasmtime, unsupported platforms.

## The default build

`rebar3 compile` runs `scripts/build-nif.sh` as a pre-hook, which:

1. Calls `scripts/fetch-wasmtime.sh`. It picks the release asset for your
   platform (`wasmtime-<version>-<arch>-<os>-c-api.tar.xz`), downloads it into
   `_build/wasmtime/<version>/`, checks its sha256 against
   `scripts/wasmtime.sha256`, and extracts it.
2. Compiles `c_src/wasmtime_nif.c` and links `libwasmtime.a` statically into
   `priv/wasmtime_nif.so`.

Requirements: a C compiler, `curl`, `tar` with xz support. The download is
12 to 16 MB and happens once per version.

The pinned version is in `scripts/wasmtime.version`.

## Runtime-only builds

The full library carries Wasmtime's compiler, which is most of the 25 MB
NIF. A runtime-only build drops it: modules are precompiled elsewhere with
`serialize/1` and the node only loads them with `deserialize/1`, the way
BEAM files are shipped without a compiler. You need it for small images and
for hosts that forbid runtime code generation.

```sh
WASMTIME_RUNTIME_ONLY=1 rebar3 compile
```

This links a 4 MB `libwasmtime` shared library, copied into `priv/` next
to an 80 KB NIF, from this repository's releases
(`wasmtime-runtime-<version>-<arch>-<os>.tar.xz`, checksums in
`scripts/wasmtime-runtime.sha256`). It has WASI, GC and threads but no
compiler and no text format:

| | full | runtime-only |
|---|---|---|
| `compile/1`, `{wat, _}`, `serialize/1` | yes | `{error, #{kind := unavailable}}` |
| `deserialize/1` | yes | yes |
| `wasi` option | yes | yes |
| host functions, memory, interrupts | yes | yes |
| NIF plus library | 25 MB | 4 MB |

`wasmtime:features/0` reports what the linked library supports:

```erlang
1> wasmtime:features().
#{compiler => false, wat => false, wasi => true}
```

Precompiled modules must come from the same Wasmtime version and a machine
with the same CPU features; see [precompiled modules](precompiled.md). Both
builds set the engine up identically so that a `.cwasm` from a full build
loads on a runtime-only build.

The `rebar3 ct` run picks up the same variables, so test a runtime-only build
with `WASMTIME_RUNTIME_ONLY=1 rebar3 ct` and the fixtures from
`scripts/precompile-fixtures.escript`; the main suites skip themselves and
`wasmtime_runtime_only_SUITE` runs.

## When there is no archive: the source build

For a platform without a prebuilt archive, or when a download is not
available, the build compiles the Wasmtime C API itself with
`scripts/build-wasmtime.sh` (the same recipe the release workflow uses),
into `_build/wasmtime/<version>/source-<full|runtime>/`, and caches it. That
needs `git`, `cmake` and a Rust toolchain; the script says so when one is
missing. `WASMTIME_SOURCE_BUILD=1` forces the source build anywhere. A
checksum mismatch on an archive that does exist is never a reason to fall
back: that build fails.

## Why a download and not a hex dependency

Hex packages are capped at 8 MB, and the C API library is 12 to 16 MB per
platform before linking. The hex package holds sources only. This is what
wasmtime-py does too, at wheel-build time instead of at compile time.

## Build offline, or with your own Wasmtime

Point the build at a directory holding `include/` and `lib/libwasmtime.a`:

```sh
WASMTIME_C_API_DIR=/opt/wasmtime-v48.0.1-x86_64-linux-c-api rebar3 compile
```

The directory must hold the same major version as `scripts/wasmtime.version`.
Wasmtime's C ABI changes between major releases.

To pre-seed the cache instead, place the tarball where the script looks:

```sh
mkdir -p _build/wasmtime/v48.0.1
cp wasmtime-v48.0.1-x86_64-linux-c-api.tar.xz _build/wasmtime/v48.0.1/
```

`WASMTIME_CACHE_DIR` moves that cache, for example to a directory shared
between builds.

## System packages

Distributions that ship the C API (headers and library), usable through
`WASMTIME_C_API_DIR`:

| Source | Ships C API |
|---|---|
| Homebrew `wasmtime` | yes, `$(brew --prefix)/{include,lib}` |
| Arch `wasmtime` | yes |
| Nix `wasmtime.dev` | yes |
| Debian, Ubuntu, Fedora | not packaged |

Check the major version matches before pointing at a system install.

## Supported platforms

Checksums are pinned for:

- macOS aarch64, x86_64
- Linux glibc aarch64, x86_64
- Linux musl aarch64, x86_64

Wasmtime also publishes Windows, Android, armv7, riscv64 and s390x C API
archives. To add one: download it, add its sha256 to `scripts/wasmtime.sha256`,
and extend the platform detection in `scripts/fetch-wasmtime.sh`.

## FreeBSD

Wasmtime publishes no FreeBSD archive, and the `wasmtime` package
(`www/wasmtime`) ships only the CLI. This repository's releases carry a
FreeBSD build of the full C API (`wasmtime-<version>-x86_64-freebsd-c-api.tar.xz`)
and of the runtime-only one, so `rebar3 compile` works as on the other
platforms. Without a matching archive (another architecture, an older
release) the source build above runs; `pkg install -y rust cmake git`
provides what it needs.

## Building the archives

`.github/workflows/wasmtime-runtime.yml` builds the runtime-only library on
native runners for macOS (arm64, x86_64), Linux glibc and musl (arm64,
x86_64) and FreeBSD (x86_64, in a VM), plus the full FreeBSD library, with
`scripts/build-wasmtime.sh`, and attaches them to the release
`wasmtime-runtime-<version>-r<revision>` (`scripts/wasmtime-runtime.rev`,
bumped for a rebuild so pinned assets are never replaced). Its checksums go into
`scripts/wasmtime-runtime.sha256` (and the FreeBSD line of
`scripts/wasmtime.sha256`) by hand, reviewed like any other change.

## Upgrade Wasmtime

See [RELEASING.md](../RELEASING.md): the pinned version ties together the
upstream archives, this repo's runtime archives, the CLI that compiles the
stdin shims and the precompiled fixtures.

## Sanitizers

```sh
WASMTIME_NIF_SANITIZE=address rebar3 compile
```

Instruments the NIF only. The runtime library has to be loaded into the
emulator first (`DYLD_INSERT_LIBRARIES` on macOS, `LD_PRELOAD` on Linux).

## Notes

- The full `.so` is about 25 MB: Wasmtime's compiler and runtime are inside
  it, with no shared library dependency. The runtime-only NIF depends on
  `priv/libwasmtime.{so,dylib}`, found through an rpath relative to the NIF.
- The download script exits non-zero on any failure. There is no pure-Erlang
  fallback in this package; for that, use `erlang_wasm`.
