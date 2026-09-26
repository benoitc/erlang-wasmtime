# Wasmtime patches

Applied by `scripts/build-wasmtime.sh` to every source build, so the
archives this project publishes (`.github/workflows/wasmtime-runtime.yml`)
carry them. On a Wasmtime bump, check each still applies and whether
upstream made it unnecessary.

- `0001-c-api-pagemap-scan.patch`: a C API setter for
  `PoolingAllocationConfig::pagemap_scan`, which Wasmtime leaves off and
  the C API does not expose. With it, a freed pool slot is reset by
  restoring only the pages the guest wrote (Linux 6.7+).
- `0002-pagemap-scan-past-max-regions.patch`: the reset scan stops after 32
  dirty regions and decommits the rest of memory, so an interpreter's
  scattered heap writes lose the benefit and fault again on the next
  request. The scan now continues from where the kernel stopped.

Measured with CPython on a GitHub x86_64 runner: request total 2.17 ms
against 3.26 ms (`keep_resident => 0`) or 4.49 ms (64 MB, unpatched); see
`docs/preinit.md`.
