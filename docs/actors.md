# Actors

`wasmtime_actor` runs a component as an OTP process that keeps its state and
handles typed messages one at a time. You need it when a component is a long
lived part of your system rather than something you call: you supervise it,
send it messages, and it posts messages back. It is erlang_wasm's
`wasm_actor`.

## Write the guest

```text
package demo:actors@0.1.0;

interface protocol {
    variant message { add(u32), added(u32) }
    enum send-error { full, closed }
}

world counter-actor {
    use protocol.{message, send-error};
    import post: func(msg: message) -> result<_, send-error>;
    export handle: func(msg: message);
}
```

The message type is yours. Keep `send-error` as it is.

## Start one

```erlang
{ok, _} = application:ensure_all_started(erlang_wasmtime),
{ok, Bytes} = file:read_file("counter.wasm"),
{ok, Counter} = wasmtime_component:prepare(Bytes),
Message = {variant, [{~"add", u32}, {~"added", u32}]},
Report = fun(Msg) -> logger:info("counter says ~p", [Msg]), ok end,
{ok, Pid} = wasmtime_actor:start_link(Counter, #{message => Message, to => Report}).
```

`message` describes the same type as the WIT. `to` is where the guest's
`post` goes: an actor's pid or registered name, `self`, or a fun answering
`ok` or `{error, full | closed}`.

## Send it messages

```erlang
ok = wasmtime_actor:send(Pid, {~"add", 5}).
```

`ok` means the message is queued, not that it was handled. `{error, full}`
means the queue is at its `capacity` (1024 unless you set it) and
`{error, closed}` that no actor is there. A message that does not fit the type
raises `badarg`.

## Supervise it

```erlang
Child = #{
    id => counter,
    start => {wasmtime_actor, start_link, [Counter, #{message => Message, register => counter}]}
}.
```

A guest that traps stops the actor with `{handle_failed, Error}`. The restarted
actor has a new instance, so its state starts over. Send to the registered
name, since the pid changes.

## Notes

- Give the guest more host functions with `imports`, and limits with
  `limits`, as for `wasmtime:instantiate/3`.
- A restart loses what was queued. Have the guest post a reply when you need
  to know a message was handled.
- Prepare the component once: every restart then skips compiling it.
