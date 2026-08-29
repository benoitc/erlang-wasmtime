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

Each of `stdin`, `stdout`, `stderr` is one of:

| Value | Effect |
|---|---|
| `none` (default) | Reads return end of file, writes are discarded |
| `inherit` | The VM's own stdin/stdout/stderr |
| `{file, Path}` | Read from or write to that host file |

## Notes

- Preview 1 only. Components and WASI preview 2 are not exposed.
- No network. The preview 1 surface Wasmtime exposes has no sockets, and no
  option here enables them.
- The stdio capture is per instance, not per call: `{file, Path}` is opened at
  instantiation and appended to by every call.
- Paths and strings are binaries or charlists; both are accepted.
