# Streams

A stream lets a guest that keeps running exchange messages with Erlang. You
need it when a guest is a server rather than a function: a script that
answers requests, a plugin with its own event loop, a program whose output
you want as it happens rather than when it ends. A host function is the
guest asking Erlang and waiting; a stream is Erlang feeding the guest, and
the guest's writes reaching you, without either side stopping.

Every instance has an inbox. `send/2` queues one message in it; the guest
reads the inbox through whichever face it can use. What the guest writes
back arrives in one process as:

```erlang
{wasmtime_stream, Ref, stdout | stderr | channel, Bytes}
```

`Ref` is `wasmtime:ref(Inst)`, the same reference that tags the instance's
host calls, so one process can serve several instances.

## Stock WASI programs: stdin and stdout

A program you did not build (QuickJS, CPython, anything compiled for
`wasm32-wasi`) imports nothing but WASI, so its channels are stdin and
stdout. Make them streams:

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{
    wasi => #{args => [~"prog"], stdin => stream, stdout => stream, stderr => capture},
    stream => self()}),
{ok, Req} = wasmtime:call_async(Inst, ~"_start", []),
Ref = wasmtime:ref(Inst),
ok = wasmtime:send(Inst, ~"first request\n"),
receive {wasmtime_stream, Ref, stdout, Reply} -> Reply end,
ok = wasmtime:close(Inst),
{ok, []} = wasmtime:await(Inst, Req).
```

- `stdin => stream`: a read blocks the guest until `send/2` queues bytes,
  then returns what is queued. Stdin is a byte stream: the guest's reads
  decide where messages start and end, so agree on a framing (one line per
  message is the usual one).
- `stdout`, `stderr => stream`: every write is one message, delivered at
  once. Whether a write is a whole line depends on the guest's buffering:
  QuickJS writes lines at once, CPython needs `-u` or `flush=True`.
- `close/1` ends the input: the guest drains what is queued, then its reads
  return end of file, which is how a read loop ends.
- `call_async/3` starts the program without waiting; `await/2,3` collects
  its exit when the loop is done. `timeout` on `await/3` and `interrupt/1`
  stop a guest parked on stdin like any other.

[Run JavaScript](javascript.md) and [Run Python](python.md) show a worker
script for each.

## Modules you build: the `erlang` imports

A module that can import functions declares these and gets them from the
runtime, no `imports` entry needed:

```wat
(import "erlang" "send" (func $send (param i32 i32)))
(import "erlang" "recv" (func $recv (param i32 i32) (result i32)))
```

- `send(ptr, len)`: the bytes at `ptr` go out as one
  `{wasmtime_stream, Ref, channel, Bytes}` message.
- `recv(ptr, cap)`: blocks until a message is queued, copies one whole
  message to `ptr` and returns its length. Returns `-1` once the inbox is
  closed and drained, and `-2 - Needed` when `cap` is smaller than the
  message, which stays queued for a larger buffer.

Unlike stdin, `recv` keeps message boundaries: one `send/2` on the Erlang
side is one `recv` in the guest. An echo loop:

```wat
(module
  (import "erlang" "send" (func $send (param i32 i32)))
  (import "erlang" "recv" (func $recv (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "serve") (local $n i32)
    (block (loop
      (local.set $n (call $recv (i32.const 0) (i32.const 1024)))
      (br_if 1 (i32.lt_s (local.get $n) (i32.const 0)))
      (call $send (i32.const 0) (local.get $n))
      (br 0)))))
```

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{stream => self()}),
{ok, Req} = wasmtime:call_async(Inst, ~"serve", []),
ok = wasmtime:send(Inst, ~"ping"),
receive {wasmtime_stream, _, channel, ~"ping"} -> ok end,
ok = wasmtime:close(Inst),
{ok, []} = wasmtime:await(Inst, Req).
```

In Rust the imports are declared as `extern "C"` functions in a
`#[link(wasm_import_module = "erlang")]` block; in C, with
`__attribute__((import_module("erlang"), import_name("recv")))`.

## Backpressure

`send/2` never blocks. The inbox holds up to `inbox_limit` bytes (default
16 MB, an instantiate option); past that `send/2` returns
`{error, #{kind := inbox_full}}` and the sender tries again once the guest
has read. After `close/1` it returns `{error, #{kind := closed}}`.

Output has no limit: the receiving process's mailbox is the buffer, as for
any Erlang message. Output sent to a process that no longer exists is
dropped and the guest does not notice, the same as `none`.

## Notes

- `stream => Pid` names the process that receives output; the default is
  the process that called `instantiate/2`. Host calls keep their own
  routing (`host => Pid`).
- The inbox is per instance and shared by stdin and `erlang.recv`; a module
  using both would compete with itself, so use one.
- `stdin => stream` puts an `fd_read` in front of Wasmtime's own for fd 0
  and forwards every other fd through a small module (`scripts/stdin-shim.wat`).
  A build with a compiler compiles it on first use; a runtime-only build
  loads the precompiled copy for its platform from `priv/shims`, produced
  by `scripts/precompile-shims.sh` for every platform with a runtime
  archive. A platform without one answers `kind => unavailable`.
- Reads by the guest with nothing queued and no `close/1` wait for as long
  as the caller lets them: bound them with `timeout` on `call/4` or
  `await/3`.
- `read_output/1` is for `capture` only; a `stream` stdout is never
  captured.
