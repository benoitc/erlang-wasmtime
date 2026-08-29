#!/bin/sh
# Drive every branch of fetch-wasmtime.sh offline, in a throwaway cache, with
# a stub builder and file:// archives. Run by `make check` and the static CI
# job. Exits non-zero on the first failing case.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT/scripts/wasmtime.version")"
FETCH="$ROOT/scripts/fetch-wasmtime.sh"
TMP="${TMPDIR:-/tmp}/wasmtime-fetch-test.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

case "$(uname -m)" in arm64|aarch64) ARCH=aarch64 ;; *) ARCH=x86_64 ;; esac
case "$(uname -s)" in Darwin) OS=macos ;; FreeBSD) OS=freebsd ;; *) OS=linux ;; esac
FULL="wasmtime-$VERSION-$ARCH-$OS-c-api"
RUNTIME="wasmtime-runtime-$VERSION-$ARCH-$OS"

# A stub builder that records its arguments and produces a valid prefix.
cat > "$TMP/build-stub.sh" <<STUB
#!/bin/sh
echo "\$1" > "$TMP/built-variant"
mkdir -p "\$2/include/wasmtime" "\$2/lib"
: > "\$2/include/wasmtime.h"
: > "\$2/lib/libwasmtime.a"
echo "\$2"
STUB
chmod +x "$TMP/build-stub.sh"

# A fake archive of the upstream layout, served from a file:// URL.
mkdir -p "$TMP/served/$FULL/include" "$TMP/served/$FULL/lib"
: > "$TMP/served/$FULL/include/wasmtime.h"
: > "$TMP/served/$FULL/lib/libwasmtime.a"
(cd "$TMP/served" && tar -cJf "$FULL.tar.xz" "$FULL")
if command -v sha256sum >/dev/null; then SUM="$(sha256sum "$TMP/served/$FULL.tar.xz" | awk '{print $1}')"
else SUM="$(shasum -a 256 "$TMP/served/$FULL.tar.xz" | awk '{print $1}')"; fi

# fetch-wasmtime.sh reads its checksum lists from scripts/; give it a copy of
# the tree with lists we control.
FAKE="$TMP/tree"
mkdir -p "$FAKE/scripts"
cp "$FETCH" "$FAKE/scripts/"
cp "$ROOT/scripts/wasmtime.version" "$FAKE/scripts/"
cp "$ROOT/scripts/wasmtime-runtime.rev" "$FAKE/scripts/"
echo "$SUM  $FULL.tar.xz" > "$FAKE/scripts/wasmtime.sha256"
: > "$FAKE/scripts/wasmtime-runtime.sha256"

n=0
pass() { n=$((n + 1)); echo "ok $n - $1"; }
fail() { echo "not ok - $1" >&2; exit 1; }
run() { # name, expected-exit, expected-stdout-regex, expected-stderr-regex, env...
    name=$1; want=$2; out_re=$3; err_re=$4; shift 4
    rm -rf "$TMP/cache" "$TMP/built-variant"
    set +e
    out="$(env "$@" WASMTIME_CACHE_DIR="$TMP/cache" WASMTIME_BUILD_SCRIPT="$TMP/build-stub.sh" \
        WASMTIME_UPSTREAM_URL="file://$TMP/served" WASMTIME_RELEASE_URL="file://$TMP/nowhere" \
        "$FAKE/scripts/fetch-wasmtime.sh" 2>"$TMP/err")"
    got=$?
    set -e
    [ "$got" = "$want" ] || { cat "$TMP/err" >&2; fail "$name: exit $got, wanted $want"; }
    echo "$out" | grep -Eq "$out_re" || fail "$name: stdout '$out' does not match '$out_re'"
    if [ -z "$err_re" ]; then
        [ ! -s "$TMP/err" ] || { cat "$TMP/err" >&2; fail "$name: expected no stderr"; }
    else
        grep -Eq "$err_re" "$TMP/err" || { cat "$TMP/err" >&2; fail "$name: stderr does not match '$err_re'"; }
    fi
    pass "$name"
}

run "explicit dir is used as is" 0 "^$TMP/served/$FULL\$" "" WASMTIME_C_API_DIR="$TMP/served/$FULL"
run "explicit dir without headers is refused" 1 "^\$" "no include/wasmtime.h" WASMTIME_C_API_DIR="$TMP/nowhere"
run "bad WASMTIME_RUNTIME_ONLY is refused" 1 "^\$" "must be 1 or unset" WASMTIME_RUNTIME_ONLY=maybe
run "full archive is downloaded and verified" 0 "/cache/$VERSION/$FULL\$" "downloading" WASMTIME_RUNTIME_ONLY=
[ ! -f "$TMP/built-variant" ] || fail "download case must not build"
run "runtime without a checksum line builds from source" 0 "/source-runtime\$" "building from source" WASMTIME_RUNTIME_ONLY=1
[ "$(cat "$TMP/built-variant")" = runtime ] || fail "stub must be asked for the runtime variant"
run "forced source build" 0 "/source-full\$" "" WASMTIME_SOURCE_BUILD=1
[ "$(cat "$TMP/built-variant")" = full ] || fail "stub must be asked for the full variant"

# A checksum line exists but the archive is not where it should be: fallback.
echo "$SUM  $RUNTIME.tar.xz" > "$FAKE/scripts/wasmtime-runtime.sha256"
run "missing download falls back to source" 0 "/source-runtime\$" "not available; building from source" WASMTIME_RUNTIME_ONLY=1

# The archive exists but its checksum is wrong: an error, never a fallback.
echo "0000000000000000000000000000000000000000000000000000000000000000  $FULL.tar.xz" > "$FAKE/scripts/wasmtime.sha256"
run "checksum mismatch is fatal" 1 "^\$" "checksum mismatch" WASMTIME_RUNTIME_ONLY=
[ ! -f "$TMP/built-variant" ] || fail "checksum mismatch must not build"

echo "1..$n"
