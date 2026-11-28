# WASI 0.3

Run a component built for WASI 0.3: one that imports `wasi:cli`,
`wasi:clocks`, `wasi:random`, `wasi:filesystem`, `wasi:sockets` or
`wasi:http` at version `0.3.x`, and whose `wasi:cli/run` is an `async
func`. You need this page when your toolchain targets 0.3, for instance
Rust's `wasip3` crate.

## Check the library

```erlang
#{wasi_p3 := true} = wasmtime:features().
```

It needs this project's patched library, which the default build downloads
(see [building](building.md)).

## Run a command

```erlang
{ok, Bin} = file:read_file("hello.component.wasm"),
{ok, Component} = wasmtime:compile(Bin),
{ok, I} = wasmtime:instantiate(Component, #{
    wasi => #{args => [~"hello"], stdout => capture}
}),
ok = wasmtime:run(I, #{timeout => 5000}),
{ok, {Out, _Err, _Dropped}} = wasmtime:read_output(I).
```

The `wasi` options are those of [WASI 0.2](wasi.md): arguments, environment,
directories, stdio (streamed too), `clocks`, `network` and `http`. A program
built through an adapter imports 0.2 as well; both are linked.

## Grant the network

```erlang
%% wasi:sockets: any address the node reaches
{ok, I} = wasmtime:instantiate(Component, #{wasi => #{network => all}}).
%% wasi:http/client: outgoing requests to any server, full builds only
{ok, J} = wasmtime:instantiate(Component, #{wasi => #{http => all}}).
```

Both also take a grant naming the addresses allowed; see
[WASI](wasi.md#grant-the-network).

Without `network` every socket operation is denied; without `http` a
component importing `wasi:http` does not link.

## Notes

- `clocks => monotonic` makes `wasi:clocks/system-clock` trap with
  `kind => clock_refused`.
- `timeout`, `interrupt/1` and a dead caller stop a program wherever it
  waits; the instance cannot be entered again.
- Work still running when `run` returns is not driven further.
- `run_serve/3` gives a `wasi:http/handler` component a request; see
  [WASI](wasi.md#serve-a-request).
- Streams and futures stay between the guest and the WASI hosts. A function
  of yours cannot take or return one (see [components](components.md)).
- erlang_wasm's `wasi_preview3:run_command/3` is `instantiate/2`, `run/1,2`
  and `read_output/1` here.
