# Throughput

What a fresh, pre-initialized CPython costs per request, measured with
hornbeam's reactor. Use these numbers to size a pool and to decide whether
per-request isolation fits your latency budget. See
[pre-initialization](preinit.md) for how the module is built.

## Run it

```bash
WASI_SDK=/path/to/wasi-sdk scripts/build-py-reactor.sh   # once, about 20 min
scripts/bench-reactor.sh                                 # about 40 s
```

`bench/reactor_bench.erl` pre-initializes `py_reactor.wasm` with
`_initialize`, `init` and one `handle`, compiles it for a pool of 256
instances (`keep_resident => 64 MB`), maps it with `deserialize_file/2`,
then per request: instantiates, calls `handle` on a `main.py` doing json
work and one `hornbeam.call`, destroys. The Linux run is the `bench`
workflow (`.github/workflows/bench.yml`), on GitHub's `ubuntu-24.04`
runner.

## Results

Apple M4 Pro (10 performance and 4 efficiency cores), macOS 27, OTP 29,
Wasmtime 48.0.1, one caller, 1000 requests. Measured on a working machine
(load average about 20), so tails are wider than on an idle one.

| Phase | p50 | p90 | p99 |
|---|---|---|---|
| instantiate | 0.17 ms | 0.29 ms | 0.64 ms |
| `handle` | 1.32 ms | 2.47 ms | 6.55 ms |
| destroy | 0.09 ms | 0.30 ms | 2.89 ms |
| **total** | **1.60 ms** | 3.60 ms | 8.27 ms |

Concurrent callers, each running requests back to back for 5 s:

| Callers | Requests/s | p50 | p99 |
|---|---|---|---|
| 1 | 690 | 1.33 ms | 2.88 ms |
| 4 | 2,461 | 1.58 ms | 2.69 ms |
| 8 | 3,930 | 1.98 ms | 2.97 ms |
| 14 | **4,291** | 3.17 ms | 4.89 ms |
| 28 | 4,123 | 6.67 ms | 11.24 ms |

| Measure | Value |
|---|---|
| Resident memory per live instance, after one request | 3.9 MB (the 40 MB image is shared) |
| One `hornbeam.call` (two host calls), 14 callers | 75 us |
| One host call, one idle instance | 2.5 us |
| `timeout => 50` on `while True: pass` | returns within 1.1 ms of the deadline |
| A global set in one request, read in the next | unset |
| A file written under one instance's writable preopen, seen by another | no |

Linux x86_64: run the `bench` workflow; its job summary is the same report.

## Reading the numbers

- Instantiation is a remap of the image: 0.17 ms for a 40 MB CPython heap,
  against 124 ms to start CPython in a fresh instance.
- On macOS every request pays page faults for what it touches, because a
  freed pool slot is remapped to zeros and the image is mapped again on
  reuse. That is most of `handle`'s 1.3 ms (0.5 ms on a heap copied up
  front), and it is kernel time that grows with concurrency: past 8 callers
  the machine spends more time in the kernel than in the guests. Linux
  restores the pages a request wrote in place, so a reused slot faults
  much less; see [preinit](preinit.md), "How the memory image is shared".
- A host call is a message to the calling process and a reply through a
  NIF. The instance thread spins for up to 20 us before sleeping, so an
  answer that comes back quickly costs no wake-up. Under full load the
  round trip is bounded by how fast the OS schedules 28 threads (14
  instance threads, 14 schedulers) on 14 cores.
- A deadline stops the guest at once: `timeout` and `interrupt/1` bump the
  engine's epoch as they fire instead of waiting for the next 10 ms tick.
