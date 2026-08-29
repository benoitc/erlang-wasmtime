# Run JavaScript

QuickJS compiled to WebAssembly gives you a JavaScript engine that runs inside
the sandbox: no filesystem, no network, no host access unless you grant it,
and a time and memory limit per run. You need it when logic has to change
without a deploy and the people writing it will write JavaScript, not Erlang.

## Get the engine

quickjs-ng publishes a WASI build with every release:

```sh
curl -fsSLo priv/qjs-wasi.wasm \
  https://github.com/quickjs-ng/quickjs/releases/download/v0.16.2/qjs-wasi.wasm
```

1.5 MB, `sha256 d2939e98c808e8b9f4164cd0d7b0398cbc0121ddf52862bcd92157d923e461cc`.
It imports only `wasi_snapshot_preview1`, so it links with the `wasi` option
and nothing else.

## Compile once, run many

```erlang
{ok, Bin} = file:read_file("priv/qjs-wasi.wasm"),
{ok, Engine} = wasmtime:compile(Bin).
```

Compiling takes about 80 ms and happens once. Each run instantiates the engine
fresh (2 ms) so nothing survives from one script to the next:

```erlang
Out = "/tmp/js-out",
{ok, Inst} = wasmtime:instantiate(Engine, #{
    wasi => #{args => [~"qjs", ~"-e", ~"console.log(1 + 2, JSON.stringify({a: [1, 2, 3]}))"],
              stdout => {file, Out}},
    memory_limit => 64 * 1024 * 1024}),
{ok, []} = wasmtime:call(Inst, ~"_start", [], #{timeout => 5000}),
{ok, ~"3 {\"a\":[1,2,3]}\n"} = file:read_file(Out).
```

`args` is the engine's command line. `-e` evaluates a string; a path runs a
file.

## Run a file

Grant the directory holding the script, read only:

```erlang
{ok, Inst} = wasmtime:instantiate(Engine, #{
    wasi => #{args => [~"qjs", ~"/app/main.js"],
              dirs => [{~"/app", "/srv/scripts", read}],
              env => [{~"GREETING", ~"hi"}],
              stdout => {file, Out},
              stderr => {file, Err}}}),
{ok, []} = wasmtime:call(Inst, ~"_start", [], #{timeout => 5000}).
```

```js
// /srv/scripts/main.js
import * as std from "qjs:std";
console.log("from file:", [1, 2, 3].map(x => x * 2).join(","));
console.log("GREETING =", std.getenv("GREETING"));
```

The script sees `/app` and nothing else. Without `dirs` it has no filesystem
at all.

## Handle failures

A thrown exception exits with status 1 and its message on stderr:

```erlang
{error, #{class := exit, status := 1}} = wasmtime:call(Inst, ~"_start", []),
{ok, ~"Error: boom\n    at <anonymous> (<cmdline>:1:11)\n\n"} = file:read_file(Err).
```

An endless loop is stopped by the `timeout`:

```erlang
{error, #{kind := timeout}} = wasmtime:call(Inst, ~"_start", [], #{timeout => 5000}).
```

A script that allocates past `memory_limit` fails inside the engine and exits
non-zero. In every case the instance can be dropped and the next run starts
clean.

## A small wrapper

`examples/js/js.erl` packages the above:

```erlang
1> c("examples/js/js.erl").
2> {ok, Engine} = js:load("priv/qjs-wasi.wasm").
3> js:eval(Engine, ~"console.log([1, 2, 3].reduce((a, b) => a + b))").
{ok, ~"6\n"}
4> js:eval(Engine, ~"for (;;) {}", #{timeout => 100}).
{error, timeout}
5> js:eval(Engine, ~"throw new Error('no')").
{error, {exit, 1, ~"Error: no\n    at <anonymous> (<cmdline>:1:7)\n\n"}}
6> js:run_file(Engine, "/srv/scripts", "main.js").
{ok, ~"from file: 2,4,6\nGREETING = undefined\n"}
```

## Notes

- Input goes in through `args`, `env`, `stdin => {file, Path}` or a granted
  directory; output comes back through `stdout`/`stderr` files. QuickJS has no
  imports of its own, so `imports` host functions do not apply to it. For
  guest code that should call Erlang directly, see
  [host functions](host-functions.md) with a module you build.
- Use the `qjs-wasi.wasm` build. `qjs-wasi-reactor.wasm` has no `_start`.
  The `wasmedge-quickjs` build imports WasmEdge socket extensions
  (`sock_open` and friends) that WASI preview 1 does not have, so it fails to
  link with `class => link`.
- `import * as std from "qjs:std"` and `qjs:os` give the script environment
  variables, files under granted directories and timers. `os.exec` and sockets
  are not reachable: there is no process or network capability in the sandbox.
- One engine module serves any number of concurrent runs; each
  `instantiate` is its own store and thread.
