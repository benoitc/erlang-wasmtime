#!/bin/sh
# Precompile the stdin stream shim for every platform with a runtime archive.
#
#   scripts/precompile-shims.sh
#
# A runtime-only build has no compiler, so `stdin => stream` loads the shim
# (the module in scripts/stdin-shim.wat, also embedded in wasmtime_nif.c)
# from priv/shims/<platform>-<plain|fuel>.cwasm. The Wasmtime CLI of the
# pinned version cross-compiles it for each target with baseline ISA flags,
# with the engine settings make_config() in wasmtime_nif.c uses: epoch
# interruption on, concurrency support off, the DRC collector, fuel per
# variant, opt level speed, and every proposal off so the module's features
# are a subset of any engine's. Rerun after a Wasmtime bump; the files are
# committed and test/wasmtime_api_SUITE.erl checks the host's.
#
# WASMTIME_CLI=/path/to/wasmtime skips the download.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/scripts/wasmtime.version")"
OUT="$ROOT/priv/shims"
CACHE="$ROOT/_build/wasmtime"

CLI="${WASMTIME_CLI:-}"
if [ -z "$CLI" ]; then
    ARCH=""; OS=""
    case "$(uname -m)" in
        arm64|aarch64) ARCH=aarch64 ;;
        x86_64|amd64)  ARCH=x86_64 ;;
    esac
    case "$(uname -s)" in
        Darwin) OS=macos ;;
        Linux)  OS=linux ;;
    esac
    NAME="wasmtime-$VERSION-$ARCH-$OS"
    EXPECTED="$(grep " $NAME.tar.xz\$" "$ROOT/scripts/wasmtime-cli.sha256" | awk '{print $1}' || true)"
    if [ -z "$EXPECTED" ]; then
        echo "precompile-shims: no pinned CLI for $(uname -s) $(uname -m); set WASMTIME_CLI" >&2
        exit 1
    fi
    mkdir -p "$CACHE"
    if [ ! -x "$CACHE/$NAME/wasmtime" ]; then
        URL="https://github.com/bytecodealliance/wasmtime/releases/download/$VERSION/$NAME.tar.xz"
        echo "precompile-shims: downloading $URL" >&2
        curl -fsSL --retry 3 -o "$CACHE/$NAME.tar.xz" "$URL"
        if command -v sha256sum >/dev/null; then ACTUAL="$(sha256sum "$CACHE/$NAME.tar.xz" | awk '{print $1}')"
        else ACTUAL="$(shasum -a 256 "$CACHE/$NAME.tar.xz" | awk '{print $1}')"; fi
        [ "$ACTUAL" = "$EXPECTED" ] || { echo "precompile-shims: checksum mismatch for $NAME.tar.xz" >&2; exit 1; }
        tar -xJf "$CACHE/$NAME.tar.xz" -C "$CACHE"
    fi
    CLI="$CACHE/$NAME/wasmtime"
fi
"$CLI" --version | grep -q " $(echo "$VERSION" | tr -d v)" ||
    { echo "precompile-shims: $CLI is not wasmtime $VERSION" >&2; exit 1; }

# Platform names as the runtime archives spell them, and their triples.
PLATFORMS="x86_64-linux:x86_64-unknown-linux-gnu
aarch64-linux:aarch64-unknown-linux-gnu
x86_64-musl:x86_64-unknown-linux-musl
aarch64-musl:aarch64-unknown-linux-musl
x86_64-macos:x86_64-apple-darwin
aarch64-macos:aarch64-apple-darwin
x86_64-freebsd:x86_64-unknown-freebsd"

OFF="-Wsimd=n -Wrelaxed-simd=n -Wbulk-memory=n -Wmulti-value=n -Wmulti-memory=n \
-Wmemory64=n -Wtail-call=n -Wwide-arithmetic=n -Wcustom-page-sizes=n -Wthreads=n \
-Wreference-types=n -Wfunction-references=n -Wgc=n -Wexceptions=n"
COMMON="-Wepoch-interruption=y -Wconcurrency-support=n -Ccollector=drc -Oopt-level=2 $OFF"

mkdir -p "$OUT"
echo "$PLATFORMS" | while IFS=: read -r platform triple; do
    for variant in plain fuel; do
        fuel=""
        [ "$variant" = fuel ] && fuel="-Wfuel=1"
        # shellcheck disable=SC2086 # COMMON and fuel are flag lists on purpose
        "$CLI" compile $COMMON $fuel --target "$triple" \
            -o "$OUT/$platform-$variant.cwasm" "$ROOT/scripts/stdin-shim.wat"
        echo "$platform-$variant.cwasm ($(wc -c < "$OUT/$platform-$variant.cwasm" | tr -d ' ') bytes)"
    done
done
