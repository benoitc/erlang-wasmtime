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
(`www/wasmtime`) ships only the CLI. Build the C API from source once, then
point the build at it:

```sh
pkg install -y rust cmake git
git clone --depth 1 --branch v48.0.1 https://github.com/bytecodealliance/wasmtime
cd wasmtime
cmake -S crates/c-api -B build -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_INSTALL_PREFIX=/opt/wasmtime-c-api
cmake --build build && cmake --install build
```

```sh
WASMTIME_C_API_DIR=/opt/wasmtime-c-api rebar3 compile
```

The install prefix holds `include/` and `lib/libwasmtime.{a,so}`; the build
script links the static archive when it is there. Expect the Wasmtime build to
take a while; the CI job caches the prefix by Wasmtime version.

## Upgrade Wasmtime

1. Edit `scripts/wasmtime.version`.
2. Download the six archives and replace `scripts/wasmtime.sha256`.
3. `rebar3 compile && rebar3 ct`.

## Sanitizers

```sh
WASMTIME_NIF_SANITIZE=address rebar3 compile
```

Instruments the NIF only. The runtime library has to be loaded into the
emulator first (`DYLD_INSERT_LIBRARIES` on macOS, `LD_PRELOAD` on Linux).

## Notes

- The resulting `.so` is about 25 MB: Wasmtime's compiler and runtime are inside
  it. There is no runtime dependency on a shared `libwasmtime`.
- The download script exits non-zero on any failure. There is no pure-Erlang
  fallback in this package; for that, use `erlang_wasm`.
