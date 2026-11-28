# Host functions

A host function is an import the module declares that you provide as an Erlang
fun. You need one whenever the guest has to reach outside its sandbox: logging,
reading a table, calling a service, sending a message.

## Declare the import in the module

```wat
(module
  (import "env" "lookup" (func $lookup (param i32 i32) (result i32)))
  (memory (export "memory") 1)
  (func (export "run") (param i32 i32) (result i32)
    local.get 0 local.get 1 call $lookup))
```

## Provide it at instantiate time

```erlang
Lookup = fun(Ctx, [Ptr, Len]) ->
    {ok, Key} = wasmtime:read_memory(Ctx, Ptr, Len),
    case ets:lookup(prices, Key) of
        [{_, Price}] -> {ok, [Price]};
        [] -> {error, ~"unknown key"}
    end
end,
{ok, Inst} = wasmtime:instantiate(Mod, #{{~"env", ~"lookup"} => Lookup}).
```

The import map is the second argument, keyed by `{Module, Name}`. Options
go in a third: `wasmtime:instantiate(Mod, Imports, #{memory_limit => ...})`.

The fun receives a context map and the arguments as a list of values.
`Ctx` holds the `instance` that called it, and the memory functions take
`Ctx` directly. Return `{ok, Results}` with exactly the values the import's
type declares, or `{trap, Reason}`. `{Module, Function}` names a host
function as well as a fun does.

## What happens on error

`{trap, Reason}` (or `{error, Reason}`) traps the guest. The call returns:

```erlang
{error, #{class := trap, kind := host_error,
          ctx := #{reason := ~"unknown key", host := {~"env", ~"lookup"}}}}
```

An exception in the fun is caught and reported the same way, with `class`,
`reason` and `stacktrace` in `ctx`. A fun that returns the wrong values gives
`reason := result_arity` or `result_type`. To answer with an error of your
own choosing, raise it with a `wasmtime_error` constructor such as
`wasmtime_error:exhaustion(host_call_limit)`. The instance stays usable.

## Where the fun runs

In the process that called `wasmtime:call/3`, while the instance thread waits.
This is the erlang-python model: the caller is the callback handler. Consequences:

- The fun can use the caller's state, dictionary and links.
- The fun can read and write guest memory through `Ctx`; the guest is stopped.
- The fun can call `wasmtime:call` on another instance. Calling the instance
  it runs on is refused with `{error, #{kind := reentrant}}`: the guest is
  parked waiting for this fun, so that call could never run. The same applies
  to a `host` process serving the call.

## Serve host calls from another process

By default the fun runs in the process that called `wasmtime:call`. To keep
callers plain clients and run every host fun in one dedicated process, name
it at instantiate time and have it answer the messages:

```erlang
Handler = spawn_link(fun Loop() ->
    receive
        {set, Inst} -> put(inst, Inst), Loop();
        Msg ->
            ok = wasmtime:handle_host_call(get(inst), Msg),
            Loop()
    end
end),
{ok, Inst} = wasmtime:instantiate(Mod, Imports, #{host => Handler}),
Handler ! {set, Inst}.
```

`handle_host_call/2` runs the import fun for a
`{wasmtime_host_call, Ref, HostId, Key, Args}` message and replies to the
guest; it returns `ignore` for any other message. Host calls made by the
module's start section during `instantiate/2` still go to the caller, which
is the only process that has the instance at that point. If the handler
process is gone the guest traps at once with `reason := host_gone`.

## Bound the wait

```erlang
{ok, Inst} = wasmtime:instantiate(Mod, Imports, #{host_timeout => 1000}).
```

If a host function has not returned after `host_timeout` milliseconds (default
30000), the guest traps with `reason := host_timeout`. The Erlang
fun itself is not killed; it runs to completion and its late result is dropped.

A `timeout` on `wasmtime:call/4` does not help here: it fires from the calling
process's `receive`, which is not running while that process executes the
host fun. Use `host_timeout` for the guest side and keep host funs short, or
hand long work to another process.

## Notes

- A host function is the guest asking Erlang and waiting for the answer. For
  the other direction, Erlang sending to a guest that keeps running, see
  [streams](streams.md).
- Only function imports can be provided from Erlang. A memory, table or global
  import fails instantiation with `kind => unsupported_import`.
- A host function can wait for the guest's own callback only by keeping the
  `funcref` it received and calling it with `call_ref/3` after the call
  returns: `call_ref` from inside the fun is refused as `reentrant`, like
  any call on the instance the fun runs on. See [references](references.md).
- Imports with exception-typed parameters or results (`exnref`)
  are refused with `kind => unsupported_type`.
- An import the module needs and the map does not provide fails instantiation
  with `class => link, kind => unknown_import`. Extra keys in the map are ignored, so one map can serve
  several modules.
- If the calling process dies during a host call, the instance is interrupted
  and the next queued call proceeds. `wasmtime:interrupt/1` from another
  process during a host call ends the guest with `kind => interrupt` at once.
