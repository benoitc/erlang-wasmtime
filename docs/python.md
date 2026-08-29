# Run Python

CPython compiled to WebAssembly runs Python scripts inside the sandbox with
the standard library, no filesystem beyond what you grant, no network, and a
time and memory cap per run. You need it when the logic arrives as Python and
must not be able to reach the host.

This is not Pyodide. Pyodide is CPython built with Emscripten for browsers
and Node: its runtime is JavaScript, so it needs a JavaScript host and cannot
load into Wasmtime. The build below is CPython's own `wasm32-wasi` target,
which imports only `wasi_snapshot_preview1`.

## Get the interpreter

```sh
curl -fsSLo python-wasi.zip \
  https://github.com/brettcannon/cpython-wasi-build/releases/download/v3.14.7/python-3.14.7-wasi_sdk-24.zip
mkdir -p /opt/python-wasi && unzip -q python-wasi.zip -d /opt/python-wasi
```

14 MB zipped, `sha256 2e064d3fb8172471d39d741348efa722349c40b96301f69968dff714999c584b`.
It unpacks to `python.wasm` (30 MB) and `lib/python3.14/`, the standard
library the interpreter reads at start.

## Compile once, run many

```erlang
{ok, Bin} = file:read_file("/opt/python-wasi/python.wasm"),
{ok, Python} = wasmtime:compile(Bin).
```

Compiling the 30 MB module takes about 350 ms, once. A run instantiates it
fresh (1 ms) and mounts the unpacked directory read-only at `/` so the
interpreter finds `lib/`:

```erlang
{ok, Inst} = wasmtime:instantiate(Python, #{
    wasi => #{args => [~"python", ~"-c", ~"import json; print(json.dumps({'a': [1, 2, 3]}))"],
              dirs => [{~"/", "/opt/python-wasi", read}],
              stdout => capture, stderr => capture},
    memory_limit => 512 * 1024 * 1024}),
{ok, []} = wasmtime:call(Inst, ~"_start", [], #{timeout => 30000}),
{ok, {~"{\"a\": [1, 2, 3]}\n", <<>>, _}} = wasmtime:read_output(Inst).
```

Interpreter start-up dominates a small script: about 100 ms for the run
above, most of it importing the standard library from the mounted directory.

## Run a file

Grant a second directory for the script and give it arguments:

```erlang
{ok, Inst} = wasmtime:instantiate(Python, #{
    wasi => #{args => [~"python", ~"/app/main.py", ~"--fast"],
              dirs => [{~"/", "/opt/python-wasi", read},
                       {~"/app", "/srv/scripts", read},
                       {~"/out", "/srv/output", write}],
              env => [{~"GREETING", ~"hi"}],
              stdout => capture, stderr => capture}}),
{ok, []} = wasmtime:call(Inst, ~"_start", [], #{timeout => 30000}),
{ok, {Out, Err, _}} = wasmtime:read_output(Inst).
```

```python
# /srv/scripts/main.py
import os, sys
print("args:", sys.argv[1:])
print("GREETING =", os.environ.get("GREETING"))
with open("/out/result.txt", "w") as f:
    f.write("done\n")
```

The script sees `/`, `/app` and `/out` and nothing else; only `/out` accepts
writes.

## Handle failures

An uncaught exception exits with status 1 and its traceback on stderr;
`sys.exit(3)` gives `status => 3`:

```erlang
{error, #{class := exit, status := 1}} = wasmtime:call(Inst, ~"_start", []),
{ok, {_, Traceback, _}} = wasmtime:read_output(Inst).
```

An endless loop is stopped by the `timeout`:

```erlang
{error, #{kind := timeout}} = wasmtime:call(Inst, ~"_start", [], #{timeout => 30000}).
```

## Talk to a running script

A script can stay up and serve requests over stdin and stdout made into
streams (see [streams](streams.md)). A streamed stdout looks like a
terminal to the interpreter, so `print` flushes at each newline.

```python
# /srv/scripts/worker.py
import sys, json
for line in sys.stdin:
    req = json.loads(line)
    sys.stdout.write(json.dumps({"sku": req["sku"], "price": 42}) + "\n")
```

```erlang
{ok, Inst} = wasmtime:instantiate(Py, #{
    wasi => #{args => [~"python", ~"/app/worker.py"],
              dirs => [{~"/", "/opt/python-wasi", read}, {~"/app", "/srv/scripts", read}],
              stdin => stream, stdout => stream, stderr => capture},
    stream => self()}),
{ok, Req} = wasmtime:call_async(Inst, ~"_start", []),
Ref = wasmtime:ref(Inst),
ok = wasmtime:send(Inst, [json:encode(#{sku => ~"A1"}), $\n]),
receive {wasmtime_stream, Ref, stdout, Line} -> json:decode(string:chomp(Line)) end,
ok = wasmtime:close(Inst),
{ok, []} = wasmtime:await(Inst, Req, 30000).
```

Each line is one message. `close/1` ends the input, the `for` loop
finishes and `await` returns.

## A small wrapper

`examples/py/py.erl` packages the above:

```erlang
1> c("examples/py/py.erl").
2> {ok, Py} = py:load("/opt/python-wasi").
3> py:eval(Py, ~"print(sum(range(10)))").
{ok, ~"45\n"}
4> py:eval(Py, ~"import os; print(os.environ['WHO'])", #{env => [{~"WHO", ~"erlang"}]}).
{ok, ~"erlang\n"}
5> py:eval(Py, ~"while True: pass", #{timeout => 200}).
{error, timeout}
6> py:eval(Py, ~"1/0").
{error, {exit, 1, ~"Traceback (most recent call last):\n  File \"<string>\", line 1, in <module>\n    1/0\n    ~^~\nZeroDivisionError: division by zero\n"}}
7> py:run_file(Py, "/srv/scripts", "hello.py").
{ok, ~"args: []\n"}
```

## Notes

- Input goes in through `args`, `env`, `stdin => {binary, Bytes}` or a
  granted directory; output comes back with `stdout`/`stderr => capture` and
  `read_output/1`, through files, or a directory granted with `write`.
  CPython has no imports of its own beyond WASI, so `imports` host
  functions do not apply.
- No sockets, no subprocesses, no threads: `socket`, `subprocess` and
  `threading` import but fail at use. `time.sleep` works (WASI
  `poll_oneoff`).
- Pure-Python packages work when placed under a granted directory on
  `PYTHONPATH` (`env => [{~"PYTHONPATH", ~"/app/site-packages"}]`). Packages
  with C extensions need to be built for `wasm32-wasi`; that is where
  Pyodide's wheel ecosystem has no counterpart here.
- One interpreter module serves any number of concurrent runs; each
  `instantiate` is its own store, memory and thread. Budget about 30 MB of
  linear memory per run for the interpreter itself.
