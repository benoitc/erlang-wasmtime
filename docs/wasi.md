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

`_start` is not run for you; call it. `proc_exit(0)` returns `{ok, []}`; any other
status returns:

```erlang
{error, #{class := exit, kind := exit, status := 3, message := ~"exited with status 3"}}
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

## Notes

- Preview 1 only. Components and WASI preview 2 are not exposed.
- No network. The preview 1 surface Wasmtime exposes has no sockets, and no
  option here enables them.
- Stdio is per instance, not per call: `{file, Path}` is opened at
  instantiation and appended to by every call, and captured output
  accumulates until `read_output/1` takes it.
- Paths and strings are binaries or charlists; both are accepted.
