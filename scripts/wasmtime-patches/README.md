# Wasmtime patches

Applied by `scripts/build-wasmtime.sh` to every source build, so the
archives this project publishes (`.github/workflows/wasmtime-runtime.yml`)
carry them. On a Wasmtime bump, check each still applies and whether
upstream made it unnecessary.

- `0001-c-api-pagemap-scan.patch`: a C API setter for
  `PoolingAllocationConfig::pagemap_scan`, which Wasmtime leaves off and
  the C API does not expose. With it, a freed pool slot is reset by
  restoring only the pages the guest wrote (Linux 6.7+).
Wasmtime 51 continues the reset scan past a full result buffer itself, which
a second patch did for 48.

Measured with CPython on a GitHub x86_64 runner, on Wasmtime 48 with both
patches: request total 2.17 ms against 3.26 ms (`keep_resident => 0`) or
4.49 ms (64 MB, first patch only); see `docs/preinit.md`.
