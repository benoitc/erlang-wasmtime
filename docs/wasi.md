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

A component gets `wasi:http/outgoing-handler` only when you grant it. Name
the addresses its requests may reach:

```erlang
Grant = #{connect => [{tcp, ~"10.0.0.0/8", 443}], resolve => allow},
{ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{http => Grant, stdout => capture}}),
ok = wasmtime:run(Inst).
```

Only the `tcp` rules under `connect` count for HTTP. A request naming a host
needs `resolve => allow`: the name is resolved once, and the connection goes to
an address that a rule allows. A refused request fails for the guest with
`HTTP-request-denied`, a name that resolves to nothing with `DNS-error`.
`http => all` allows any server the node can reach, the loopback included, so
grant it only to code you would let call any URL.

The body of a request and the body of a response are each bounded to 8 MiB;
past that the guest's request fails. `http_max_body_bytes` changes the bound,
and `http_max_field_bytes` bounds the headers the guest builds (128 KiB when
left out; a guest that goes past it traps):

```erlang
#{http => Grant, http_max_body_bytes => 64 * 1024 * 1024, http_max_field_bytes => 16384}.
```

Without the grant a component that imports `wasi:http` does not link. A
runtime-only build has no `wasi:http` (`features/0`, `wasi_http`) and answers
`kind => unavailable`.

### Send requests through your own module

Wasmtime sends the guest's requests over HTTP/1.1. To send them yourself, to
log them, to add credentials, or to speak another protocol, name a module with
the `wasmtime_http_transport` behaviour:

```erlang
-module(my_transport).
-behaviour(wasmtime_http_transport).
-export([request/2]).

request(#{method := Method, host := Host, address := Address, port := Port,
          path := Path, headers := Headers, body := Body} = Request, Timeout) ->
    logger:info("wasi:http ~s ~s:~p~s", [Method, Host, Port, Path]),
    %% send it to Address, with Host for the Host header and TLS, then:
    {ok, 200, [{~"content-type", ~"text/plain"}], ~"hello"}.
```

```erlang
#{wasi => #{http => Grant, http_transport => my_transport}}
```

- The grant is checked before your module runs. Connect to `address`, never
  resolve `host` again: another answer would be an address nobody checked.
- The request also carries `scheme`, `tls` (the `http_tls` option, for your
  TLS client; `wasmtime_http_transport:tls_opts/2` adds the server name), the
  guest's `connect_timeout`, `first_byte_timeout` and `between_bytes_timeout`
  in milliseconds or `undefined`, and `max_body_bytes`.
- `Timeout` is the deadline of the whole exchange, 30 seconds; `deadline/1`
  and `within/2` split it between your steps.
- Answer `{ok, Status, Headers, Body}`, or a `wasi:http` error code by its WIT
  name: `{error, {~"connection-refused", none}}`.
- The module runs in the process serving the instance's host calls, and the
  guest waits for it, so a call's `timeout` takes effect once it returns. It
  cannot call the instance it is serving.
- A module that raises, or answers something else, fails the call with
  `kind => host_error`; in a `host` process, which has no call to answer, the
  call ends as interrupted.

A library without this project's patches (`features/0`,
`wasi_http_transport`) answers `kind => unavailable`.

### Serve a request

A component that exports `wasi:http/incoming-handler` (WASI 0.2) or
`wasi:http/handler` (WASI 0.3) answers requests. Give it one:

```erlang
{ok, Bin} = file:read_file("hello.component.wasm"),
Request = #{method => ~"GET", path => ~"/", headers => [], body => <<>>},
{ok, Status, Headers, Body} = wasmtime_wasi_preview2:run_serve(Bin, Request, #{}).
```

Each call instantiates the component, calls its handler, reads the response
and destroys the instance. The component is compiled once while the
`erlang_wasmtime` application runs.

- `Request` also takes `scheme` (`~"http"`), `authority` (`~"localhost"`) and
  `trailers`. Headers a guest may not set, `host` and `connection` among them,
  do not reach it.
- A WASI 0.3 response with trailers is `{ok, Status, Headers, Body,
  Trailers}`.
- The options are those of `run_command/3`: `env`, `preopen`, `network`,
  `timeout`, `fuel` and the rest. Without `network` the handler's own
  requests are refused.
- The response body is bounded to 8 MiB; `http_max_body_bytes` changes that.

| Result | Means |
|---|---|
| `{error, no_incoming_handler}` | the component exports no handler |
| `{error, no_response}` | the handler returned, or a 0.2 one trapped, without a response |
| `{error, {Code, Payload}}` | a `wasi:http` error code, such as `{~"HTTP-response-body-size", {some, 8388608}}` |
| `{error, #{kind := _}}` | the call failed, as any call does: a trap, `timeout`, `out_of_fuel` |

Serving needs a full build with this project's patches (`features/0`,
`wasi_http_serve`).

### Grant the network

`wasi:sockets` is denied by default: every network operation answers
`access-denied`. A grant lists what the component may do, in the form of
erlang_wasm's `wasi_net`:

```erlang
Grant = #{
    connect => [{tcp, ~"192.0.2.10", 5432}, {udp, ~"10.0.0.53", 53}],
    listen => [{tcp, {127, 0, 0, 1}, {8000, 8100}}],
    resolve => allow
},
{ok, I} = wasmtime:instantiate(Component, #{wasi => #{network => Grant}}),
ok = wasmtime:run(I, #{timeout => 5000}).
```

- An address is a tuple or a binary, with an optional prefix length
  (`~"2001:db8::/32"`). Host names are not accepted: a rule is about the
  address reached. An IPv4-mapped IPv6 address matches the IPv4 rules.
- A port is one number, `{First, Last}` or `any`.
- `listen` rules cover listening and binding a port you name. Binding port 0
  needs no rule.
- Name lookup is off unless `resolve => allow`. `tcp => false` or
  `udp => false` turns a transport off whatever the rules say.
- A grant that cannot be read raises `{bad_net_grant, Term}`. erlang_wasm's
  `max_sockets` and `timeout` are refused with `kind => unsupported_option`.

`network => all` allows TCP, UDP and name lookup, to or from any address. A
guest waiting on a peer is stopped by `timeout`, `interrupt/1` or its
caller's death, like any component call (`features/0`, `component_async`).
Grants need a library with this project's patches (`features/0`,
`wasi_sockets` and `wasi_limits`) and otherwise answer
`kind => unavailable`.

## Bound what a component asks of the host

```erlang
{ok, I} = wasmtime:instantiate(Component, Imports, #{
    wasi => #{},
    resource_limit => 256,
    transfer_limit => 512 * 1024 * 1024
}).
```

- `resource_limit` caps the host resource handles live in the process that
  serves host calls (`kind => resource_limit_reached`), and the resources
  WASI holds for the instance: files, streams, sockets.
- `transfer_limit` is how many bytes one call may copy from the component to
  the host, 128 MiB when left out (`kind => hostcall_fuel`). A `list<u8>`
  counts about 32 per byte, so a few megabytes reach the default.

A program that asks where it starts gets what you give as `initial_cwd`:

```erlang
#{wasi => #{dirs => [{~"/work", "/srv/job", write}], initial_cwd => ~"/work"}}.
```

## Notes

- Components get WASI 0.2 (above); core modules get preview 1.
- No network for core modules: preview 1 as Wasmtime exposes it has no
  sockets, and a network grant answers `kind => unsupported`.
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
