# Wasmtime patches

Applied by `scripts/build-wasmtime.sh` to every source build, so the
archives this project publishes (`.github/workflows/wasmtime-runtime.yml`)
carry them. On a Wasmtime bump, check each still applies and whether
upstream made it unnecessary.

- `0001-c-api-pagemap-scan.patch`: a C API setter for
  `PoolingAllocationConfig::pagemap_scan`, which Wasmtime leaves off and
  the C API does not expose. With it, a freed pool slot is reset by
  restoring only the pages the guest wrote (Linux 6.7+).
- `0002-c-api-wasi-sockets.patch`: C API switches for
  `WasiCtxBuilder::allow_tcp` and `allow_udp`, both off by default. Without
  them `wasi_config_inherit_network` gives a guest no socket
  (bytecodealliance/wasmtime#15388).

- `0003-c-api-blocking-component-calls.patch`: instantiate, call and resource
  drop that run Wasmtime's async path to completion on the calling thread,
  inside Tokio, and that another thread can cancel. The C API's own
  `wasmtime_call_future_poll` polls with no waker and outside Tokio, where a
  WASI timer panics.

- `0004-c-api-wasi-0-3.patch`: the C API links only the WASI 0.2 hosts. Adds
  the 0.3 ones, `wasi:http` included, and builds `wasmtime-wasi` and
  `wasmtime-wasi-http` with their `p3` features.

- `0005-c-api-wasi-limits-and-rules.patch`: address rules for
  `wasi:sockets` and for outgoing `wasi:http` (which connects to the address
  it checked), the initial directory, and the store's limits on WASI
  resources, copied data, header size and HTTP bodies. The one patch that
  changes more than the C API: `wasmtime-wasi-http` gains the filtered send.

Wasmtime 51 continues the reset scan past a full result buffer itself, which
a second patch did for 48.

Measured with CPython on a GitHub x86_64 runner, on Wasmtime 48 with both
patches: request total 2.17 ms against 3.26 ms (`keep_resident => 0`) or
4.49 ms (64 MB, first patch only); see `docs/preinit.md`.
