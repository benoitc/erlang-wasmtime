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
(load average about 20), so tails are wider than on an idle one. These runs
predate the shared linker, which later took instantiation from 0.17 ms to
0.07 ms on the same machine; the other phases did not change.

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

Linux x86_64: GitHub's `ubuntu-24.04` runner, AMD EPYC 7763, 4 vCPUs,
Linux 6.17, OTP 28, this project's patched Wasmtime 48.0.1 archive. The
`bench` workflow's job summary is the full report.

| Phase | p50 | p90 | p99 |
|---|---|---|---|
| instantiate | 0.10 ms | 0.12 ms | 0.14 ms |
| `handle` | 1.88 ms | 2.14 ms | 2.23 ms |
| destroy | 0.21 ms | 0.24 ms | 0.27 ms |
| **total** | **2.19 ms** | 2.48 ms | 2.59 ms |

| Callers | Requests/s | p50 | p99 |
|---|---|---|---|
| 1 | 443 | 2.18 ms | 2.63 ms |
| 4 | 972 | 4.01 ms | 6.10 ms |
| 14 | 1,074 | 12.85 ms | 21.47 ms |

| Measure | Value |
|---|---|
| Resident memory per live instance | 1.0 MB |
| One `hornbeam.call`, 14 callers on 4 vCPUs | 131 us |
| `timeout => 50` on `while True: pass` | returns within 0.64 ms of the deadline |
| Isolation (globals, files) | holds |

Four vCPUs cap the concurrent rows; per core, the runner serves about 270
requests a second against the M4's 300. `handle` is CPython itself: its
bootstrap string and `main.py` are compiled from source on every request.

## Reading the numbers

- Instantiation is a remap of the image plus a WASI context: 0.07 to
  0.10 ms for a 40 MB CPython heap, against 124 ms to start CPython in a
  fresh instance. The linker and its import checks are built once per
  module and import shape.
- On macOS every request pays page faults for what it touches, because a
  freed pool slot is remapped to zeros and the image is mapped again on
  reuse. That is most of `handle`'s 1.3 ms (0.5 ms on a heap copied up
  front), and it is kernel time that grows with concurrency: past 8 callers
  the machine spends more time in the kernel than in the guests. Linux,
  with this project's Wasmtime archive, restores the pages a request wrote
  in place, so a reused slot faults ten times less; see
  [preinit](preinit.md), "How the memory image is shared".
- A host call is a message to the calling process and a reply through a
  NIF. The instance thread spins for up to 20 us before sleeping, so an
  answer that comes back quickly costs no wake-up. Under full load the
  round trip is bounded by how fast the OS schedules 28 threads (14
  instance threads, 14 schedulers) on 14 cores.
- A deadline stops the guest at once: `timeout` and `interrupt/1` bump the
  engine's epoch as they fire instead of waiting for the next 10 ms tick.
