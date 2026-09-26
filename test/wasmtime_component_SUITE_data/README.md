# Component fixtures

Built binaries, so the suite needs no Rust toolchain.

- `clocks.component.wasm`: from `test/fixtures/components/clocks`, built by
  `scripts/build-component-fixtures.sh`.
- The others come from erlang_wasm (`test/fixtures/component/<name>`, built
  by its `scripts/build-component-fixture.sh`, commit 0332a17), so both
  runtimes are tested against the same guests and the same expected terms:
  - `vectors`: echoes one value of every WIT type;
  - `counter`: an exported resource with a constructor and methods;
  - `hostcall`, `hostagg`: import `example:host/clock` and `example:agg/host`;
  - `realupper`, `argv`, `envvar`, `exitcode`: unmodified Rust programs
    built for `wasm32-wasip2`;
  - `wasiver`: imports `wasi:random/random@0.2.0`.

erlang_wasm's other WASI fixtures import `wasi:*` interfaces without a
version, which erlang_wasm accepts and Wasmtime does not; they are not used
here.
