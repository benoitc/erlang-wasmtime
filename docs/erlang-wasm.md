# Switch between erlang_wasm and erlang_wasmtime

[erlang_wasm](https://github.com/benoitc/erlang_wasm) runs WebAssembly in
Erlang; this library runs it with Wasmtime, as native code. They share names,
options and error shapes, so you can write your code once and choose the
runtime in your configuration. You need this when you want to try one against
the other, ship where one of them cannot build, or move over module by module.
This page compares erlang_wasm 0.13.0 with this library.

## Add the runtimes

Add the one you use, or both. Their modules never collide.

```erlang
{deps, [
    %% the application is `wasm`, the Hex package `erlang_wasm`
    {wasm, {pkg, erlang_wasm}},
    {erlang_wasmtime,
        {git, "https://github.com/benoitc/erlang-wasmtime", {branch, "main"}}}
]}.
```

This library builds a NIF and needs a C compiler; erlang_wasm does not. See
[building](building.md).

## Choose the runtime in one place

Keep every difference in one module of your own. The rest of your code calls
it, or calls `my_wasm:mod(core)` for what both runtimes spell the same.

```erlang
-module(my_wasm).
-export([runtime/0, mod/1, start/0, instantiate/4, run_program/2]).

runtime() ->
    application:get_env(my_app, wasm_runtime, wasmtime).

mod(Role) ->
    maps:get(Role, modules(runtime())).

modules(wasmtime) ->
    #{
        app => erlang_wasmtime,
        core => wasmtime,
        error => wasmtime_error,
        limits => wasmtime_limits,
        worker => wasmtime_instance_worker,
        script_worker => wasmtime_script_worker,
        javascript => wasmtime_javascript_command,
        python => wasmtime_python_command
    };
modules(wasm) ->
    #{
        app => wasm,
        core => wasm,
        error => wasm_error,
        limits => wasm_limits,
        worker => wasm_instance_worker,
        script_worker => wasm_script_worker,
        javascript => wasm_javascript_command,
        python => wasm_python_command
    }.

start() ->
    {ok, _} = application:ensure_all_started(mod(app)),
    ok.

%% WASI is an option here and an import map on erlang_wasm.
instantiate(Module, Imports, none, Opts) ->
    (mod(core)):instantiate(Module, Imports, Opts);
instantiate(Module, Imports, Wasi, Opts) ->
    case runtime() of
        wasmtime ->
            wasmtime:instantiate(Module, Imports, Opts#{wasi => Wasi});
        wasm ->
            All = maps:merge(wasi_preview1:imports(Wasi), Imports),
            wasm:instantiate(Module, All, Opts)
    end.

%% Run a WASI program: {ok, ExitStatus, Stdout, Stderr}.
run_program(Module, Wasi) ->
    run_program(runtime(), Module, Wasi).

run_program(wasm, Module, Wasi) ->
    wasi:run(Module, Wasi);
run_program(wasmtime, Module, Wasi) ->
    Captured = Wasi#{stdout => capture, stderr => capture},
    maybe
        {ok, Inst} ?= wasmtime:instantiate(Module, #{}, #{wasi => Captured}),
        Result = wasmtime:call(Inst, ~"_start", []),
        {ok, {Out, Err, _Dropped}} = wasmtime:read_output(Inst),
        ok = wasmtime:destroy(Inst),
        case Result of
            {ok, _} -> {ok, 0, Out, Err};
            {error, #{ctx := #{wasi_exit := Status}}} -> {ok, Status, Out, Err};
            {error, _} -> Result
        end
    end.
```

Switch in `sys.config`, `wasm` or `wasmtime`:

```erlang
[{my_app, [{wasm_runtime, wasm}]}].
```

## Write the calls both accept

Load with `load/1`, instantiate with `instantiate/3`, and match errors on
`class` and `kind`.

```erlang
ok = my_wasm:start(),
W = my_wasm:mod(core),
{ok, Module} = W:load(Bytes),

Log = fun(Ctx, [Ptr, Len]) ->
    {ok, Text} = W:read_memory(Ctx, Ptr, Len),
    logger:info("guest: ~ts", [Text]),
    {ok, []}
end,
Imports = #{{~"env", ~"log"} => Log},

{ok, Inst} = my_wasm:instantiate(Module, Imports, none, #{max_memory_pages => 256}),
case W:call(Inst, ~"run", [-1]) of
    {ok, Results} -> {ok, Results};
    {error, #{class := trap, kind := Kind}} -> {trapped, Kind};
    {error, #{class := exhaustion, kind := Kind}} -> {over_limit, Kind};
    {error, Error} -> {error, iolist_to_binary(W:format_error(Error))}
end.
```

In a host function:

- take what you need from `Ctx` with `read_memory/3`, `write_memory/3` and
  `memory_size/1`, or `maps:get(instance, Ctx)`; the other keys are not
  shared
- answer `{ok, Results}` or `{trap, Reason}`

For WASI, pass only the keys both take:

```erlang
Wasi = #{
    args => [~"prog"],
    env => #{~"MODE" => ~"production"},
    dirs => [{~"/data", "/srv/app/data", read}],
    clocks => [monotonic]
},
{ok, Module} = (my_wasm:mod(core)):load(Program),
{ok, Status, Stdout, Stderr} = my_wasm:run_program(Module, Wasi).
```

## Put deadlines in a worker

On erlang_wasm a `timeout` given to a call does not stop the guest. The
instance worker stops it on both.

```erlang
Worker = my_wasm:mod(worker),
Limits = my_wasm:mod(limits),
{ok, Pid} = Worker:start_link(Module, #{
    imports => Imports,
    limits => Limits:merge(Limits:untrusted(), #{fuel => infinity})
}),
{error, #{class := exhaustion, kind := timeout}} =
    Worker:call(Pid, ~"spin", [], 100).
```

Take the limit presets from the runtime you are on, as above: erlang_wasm's
hold limits this library refuses. Its `untrusted/0` also bounds fuel, which
ends an endless loop with `out_of_fuel` before the deadline does; set `fuel`
yourself when the two must answer alike.

## Run scripts

The script workers take the same calls. For JavaScript both adapters run the
same file, wasmedge-quickjs `v0.5.0-alpha` (see [javascript](javascript.md));
for Python, give each adapter the build its own guide names.

```erlang
ScriptWorker = my_wasm:mod(script_worker),
{ok, S} = ScriptWorker:start_link(my_wasm:mod(javascript), #{path => Qjs}),
{ok, #{result := Result}} = ScriptWorker:run(S, Source, #{~"value" => 41}).
```

Directories for request files come from `scratch_roots` in the environment of
the runtime's application, `wasm` or `erlang_wasmtime`.

## Handle what differs

| Subject | erlang_wasm | Here | In shared code |
|---|---|---|---|
| Integer results | an argument handed back can stay unsigned | always signed | pass signed values |
| NaN | `{nan, Sign, Payload}` | `nan` | match both |
| `exports/1` values | `{Kind, Index}` | `{Kind, undefined}` | match the kind only |
| `msg` and `ctx` | its own wording and extra keys | Wasmtime's detail in `ctx.detail` | match `class` and `kind` |
| `call_indirect` past the table | `undefined_element` | `out_of_bounds_table_access` | match both |
| An instance's owner | the process that made it | any process with the handle | use it where you made it, or use a worker |
| A call after `destroy/1` | raises | `{error, #{kind := stopped}}` | do not call it |
| `validate/1` | takes a module | takes a module or bytes | pass a module |
| Fuel | `fuel` at instantiate or per call | the same, on a module loaded with `fuel => true` | load with `load(Bytes, #{fuel => true})`, which both accept |
| `timeout` on a call | does not stop the guest | stops it | use a worker |
| Snapshot of an instance with imports | needs `snapshot_hooks` | `snapshot_hooks` is refused | add the option on erlang_wasm only |
| Saved snapshot files | its own format | its own format | save one per runtime |
| `max_depth`, `max_host_calls`, `max_heap_words` | enforced | refused | leave them out |
| `{error, Reason}` from a host function | not accepted | traps | answer `{trap, Reason}` |

Only erlang_wasm has `wasm:encode/1`, the compiled tier and the `link`
option. Only this library has [precompiled modules](precompiled.md),
`preinit/3`, streams to a process and `interrupt/1`.
[Features](features.md) lists every error and every refusal.

## What does not switch yet

Keep this code on one runtime:

| You use | Why |
|---|---|
| components | erlang_wasm calls them through `wasm_component`; here they go through `wasmtime`. The terms for WIT values are the same, and so are `host_new`, `host_get`, `host_update`, `host_drop` and `host_live` |
| WASI import maps you change or wrap | Wasmtime implements WASI itself |
| serving or filtering HTTP, address rules on sockets, `wasi:nn`, streams of a component | not available here |
| `wasm_actor`, snapshot script adapters, the reaper, the conformance kit | not available here |

## Notes

- Compiled modules, instances, references and snapshots belong to the
  runtime that made them. Switch at start-up, not while they live.
- Running both in one node works: each is its own application.
- Test your suite under both settings; a difference that matters to your
  code shows there first.
