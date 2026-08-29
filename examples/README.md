# Examples

## js

QuickJS compiled to WASI, wrapped in `js:load/1`, `js:eval/2,3` and
`js:run_file/3`. The guide is [docs/javascript.md](../docs/javascript.md).

## py

CPython compiled to WASI, wrapped in `py:load/1`, `py:eval/2,3` and
`py:run_file/3`. The guide is [docs/python.md](../docs/python.md).

## bridge

A guest module that talks to the VM through four host functions, and a
gen_server that owns the instance: `examples/bridge/counter.wat` and
`examples/bridge/bridge.erl`.

What crosses the boundary:

| Direction | How |
|---|---|
| Guest reads Erlang state | `erlang.kv_get(ptr, len) -> i32`: the host fun looks the key up in ETS |
| Guest writes Erlang state | `erlang.kv_put(ptr, len, value)`: `ets:insert/2` |
| Guest logs | `erlang.log(ptr, len)`: `logger:notice/2` with the string read from guest memory |
| Guest notifies processes | `erlang.notify(ptr, len, value)`: the host fun casts to the gen_server, which sends `{bridge, Key, Value}` to subscribers |
| Erlang hands the guest a string | `wasmtime:write_memory/3` into a scratch area, call `upcase(ptr, len)`, `wasmtime:read_memory/3` |

Run it from a `rebar3 shell`:

```erlang
1> c("examples/bridge/bridge.erl").
2> {ok, _} = bridge:start_link("examples/bridge/counter.wat").
3> bridge:subscribe().
4> bridge:bump(5).
5
5> bridge:bump(2).
7
6> flush().
Shell got {bridge,<<"hits">>,5}
Shell got {bridge,<<"hits">>,7}
7> bridge:upcase(<<"hello from erlang">>).
<<"HELLO FROM ERLANG">>
```

Notes:

- Host funs run inside the gen_server process (it is the one calling
  `wasmtime:call`), so they can read its ETS table directly. To change the
  server's own state they cast to it; the cast is handled after the call
  returns.
- The guest sees strings only as `(ptr, len)` into its linear memory. Reading
  and writing that memory is the host's job, and it is allowed while the guest
  waits inside a host function or is idle.
- `timeout => 1000` on `bump` bounds a misbehaving guest; `memory_limit`
  bounds its memory.
