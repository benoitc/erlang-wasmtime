# py_reactor

The two C files `scripts/build-py-reactor.sh` links into CPython for the
benchmark in `bench/reactor_bench.erl`:

- `worker_reactor.c`: an `init()`/`handle()` reactor over CPython, from
  erlang_wasm (`test/fixtures/lang/python_reactor`).
- `hornbeam_caps.c`: the `_hornbeam` module, whose `call(name, payload)`
  crosses into the host through the `hornbeam.call` and `hornbeam.take`
  imports, from hornbeam (`wasm/py_reactor`).

Copied so the benchmark builds without either repository; keep them in step
with their origin when the reactor protocol changes.
