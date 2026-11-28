# WASI

WASI preview 1 gives a guest built with a standard toolchain (Rust
`wasm32-wasip1`, clang, Zig, Go) its `main`, arguments, environment, files and
stdio. You need it for such binaries; a freestanding module with only your own
imports does not.

Nothing is granted by default. Without a `wasi` option the WASI imports are
undefined and instantiation fails with a link error. With `wasi => #{}` the guest
has arguments, environment and stdio that lead nowhere, and no filesystem.

## Run a program

```erlang
{ok, Mod} = wasmtime:compile(Bin),
{ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{
    args   => [~"prog", ~"--fast"],
    env    => [{~"HOME", ~"/"}],
    stdout => {file, "/tmp/out.txt"},
    stderr => inherit}}),
{ok, []} = wasmtime:call(Inst, ~"_start", []).
```

`_start` is not run for you; call it. A `_start` that returns answers
`{ok, []}`. `proc_exit`, with any status including 0, traps as in
erlang_wasm:

```erlang
{error, #{class := trap, kind := host_error, ctx := #{wasi_exit := 3}}}
```

## Run a program and collect its output

```erlang
{ok, Mod} = wasmtime:load_file("hello.wasm"),
{ok, Status, Stdout, Stderr} = wasmtime_wasi:run(Mod, #{args => [~"hello"]}).
```

`wasmtime_wasi:run/2` calls `_start` and answers the exit status, 0 when the
program returns. A trap that is not an exit is `{error, Error}`. For a
component, give it its input and take its output:

```erlang
{ok, Component} = file:read_file("upper.wasm"),
{ok, #{stdout := ~"HELLO", exit_code := 0}} =
    wasmtime_wasi_preview2:run_command(Component, ~"hello").
```

## Grant a directory

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{
    dirs => [{~"/data", "/srv/app/data", read},
             {~"/out",  "/srv/app/out",  write}]}}).
```

Each entry is `{GuestPath, HostPath, read | write}`. The guest sees only these
trees; `read` refuses every mutating operation. No `dirs` means no filesystem at
all, not the working directory.

## Stdio

| Value | `stdin` | `stdout`, `stderr` |
|---|---|---|
| `none` (default) | reads return end of file | writes are discarded |
| `inherit` | the VM's own | the VM's own |
| `{file, Path}` | read from that host file | appended to that host file |
| `{binary, Bytes}` | the bytes, then end of file | |
| `capture` | | kept in memory, read with `read_output/1` |
| `stream` | what `send/2` queues, as the guest reads it | each write sent to the `stream` process at once |

Capture is the simplest way to get a script's output back:

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{
    args => [~"prog"], stdin => {binary, Input}, stdout => capture, stderr => capture}}),
{ok, []} = wasmtime:call(Inst, ~"_start", []),
{ok, {Stdout, Stderr, {0, 0}}} = wasmtime:read_output(Inst).
```

`read_output/1` returns what accumulated since the last call and empties the
buffers; it works while the guest runs, so another process can drain a
long-running guest. `output_limit` (default 16 MB per stream) caps what is
kept: the guest still sees complete writes, and the two counters in the
result say how many bytes were dropped.

`stream` is for a guest that keeps running and exchanges messages with
Erlang; see [streams](streams.md).

`args => inherit` and `env => inherit` hand the guest the VM's own command
line and environment; the default is none of either. The inherited command
line is what the platform gives a dynamically loaded library: the VM's
arguments on Linux (glibc) and macOS, an empty list on FreeBSD.

## Send output to a process or a fun

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{}, #{wasi => #{
    stdout => self(),
    stderr => fun(Bytes) -> logger:warning("~ts", [Bytes]) end}}).
```

A pid receives `{wasi_output, From, Bytes}`; an atom names an io device such
as `standard_io`. The process waiting for the call delivers the bytes, so they
have all arrived when it returns. A fun that raises loses those bytes and the
call goes on.

## Make randomness repeatable

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{}, #{wasi => #{random => {seed, 42}}}).
```

With a seed, `random_get` answers the same bytes every run; `random => none`
makes it fail with `ENOTCAPABLE`. Both are for core modules: a component's
randomness is Wasmtime's.

## Keep the guest off the wall clock

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{clocks => monotonic}}).
```

With `clocks => monotonic` the guest reads the host's monotonic clock and
nothing else: wall time and process or thread CPU time answer `ENOTCAPABLE`
(Python's `time.time()` raises `OSError`). Use it when a guest must not
learn the date or time of day, such as a workflow that has to replay the
same way. Durations still work: `time.monotonic()` and `time.sleep()` do.

The monotonic clock is the host's own, not one starting at
instantiation, so readings a [pre-initialized](preinit.md) guest took
during its init are still in the past. The default, `clocks => all`, is
Wasmtime's WASI with every clock.

## WASI 0.2

For a component built for WASI 0.3, see [WASI 0.3](wasi-0-3.md).

A [component](components.md) instantiated with a `wasi` option gets WASI
0.2 (Wasmtime's `wasi:cli`, `wasi:io`, `wasi:clocks`, `wasi:random`,
`wasi:filesystem`), configured by the same keys as preview 1 above. A
command component runs with `run/1,2`:

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{args => [~"prog"], stdout => capture}}),
ok = wasmtime:run(Inst).
```

| Preview 1 | WASI 0.2 |
|---|---|
| `_start` called with `call/3` | `run/1,2`, which calls `wasi:cli/run#run` |
| `proc_exit(N)`: an error with `ctx.wasi_exit` | `exit`: `ok`, or an error with `ctx.wasi_exit := 1`; WASI 0.2 carries success or failure only |
| `clocks => monotonic`: a refused clock answers `ENOTCAPABLE` | `clocks => monotonic`: `wall-clock` `now` and `resolution` trap with `kind => clock_refused`, since they have no error case |
| `stdin => stream`, `stdout => stream` | the same, through the same pipe and callback |
| a streamed stdout reports itself a terminal | it does not: Wasmtime's custom stdout is no terminal for WASI 0.2, so a program's C library buffers it; flush in the guest |

### Let a component make HTTP requests

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{http => all, stdout => capture}}),
ok = wasmtime:run(Inst).
```

`http => all` gives the component `wasi:http/outgoing-handler`. It is off
by default, and it is all or nothing: the component may send requests to
any server the node can reach, and Wasmtime makes the request. There is no
rule per address and no way to supply the transport, so grant it only to
code you would let call any URL. Without the grant a component that imports
`wasi:http` does not link. A runtime-only build has no `wasi:http`
(`features/0`, `wasi_http`) and answers `kind => unavailable`.

Serving requests (`wasi:http/incoming-handler`) is not available.

### Sockets

`wasi:sockets` is denied by default: every network operation answers
`access-denied`. Grant it to a component you would let reach anything the
node reaches:

```erlang
{ok, I} = wasmtime:instantiate(Component, #{wasi => #{network => all}}),
ok = wasmtime:run(I, #{timeout => 5000}).
```

The grant covers TCP, UDP and name lookup, to or from any address, the
loopback included; there is no rule per address. A guest waiting on a peer
is stopped by `timeout`, `interrupt/1` or its caller's death, like any
component call (`features/0`, `component_async`). A library
without this project's patches (`features/0`, `wasi_sockets`) answers
`kind => unavailable`.

## Notes

- Components get WASI 0.2 (above); core modules get preview 1.
- No network for core modules: preview 1 as Wasmtime exposes it has no
  sockets, and `network => all` answers `kind => unsupported`.
- Randomness (`random_get`) is the host's cryptographic generator, seeded
  per instance. A pre-initialized module starts with whatever its init drew;
  see [preinit](preinit.md).
- `clocks => monotonic` covers the clock calls. A guest can still see file
  modification times through `fd_filestat_get` on the directories you grant,
  and a `poll_oneoff` subscription on the wall clock waits as asked.
- Stdio is per instance, not per call: `{file, Path}` is opened at
  instantiation and appended to by every call, and captured output
  accumulates until `read_output/1` takes it.
- Paths and strings are binaries or charlists; both are accepted.
