%% Component model async: `async func` exports and imports, stopping a call
%% that waits inside WASI, and the types that cannot cross.
-module(wasmtime_component_async_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    async_export/1,
    async_export_trap/1,
    async_import/1,
    async_precompiled/1,
    pooled_calls/1,
    reference_types_off/1,
    stream_result_refused/1,
    nested_result_refused/1,
    stream_param_refused/1,
    host_import_stream_refused/1,
    interrupt_waiting_guest/1,
    caller_death_frees_waiting_guest/1
]).

all() ->
    [
        async_export,
        async_export_trap,
        async_import,
        async_precompiled,
        pooled_calls,
        reference_types_off,
        stream_result_refused,
        nested_result_refused,
        stream_param_refused,
        host_import_stream_refused,
        interrupt_waiting_guest,
        caller_death_frees_waiting_guest
    ].

init_per_suite(Config0) ->
    case wasmtime_test:needs([compiler, wasi], Config0) of
        {skip, _} = Skip ->
            Skip;
        Config ->
            case wasmtime:features() of
                #{component_async := true} -> Config;
                #{component_async := false} -> {skip, "this library cannot run component async"}
            end
    end.

end_per_suite(_) -> ok.

%% `double` is an async export: it hands its result to task.return and exits.
double() ->
    ~"""
    (component
      (core func $ret (canon task.return (result u32)))
      (core module $m
        (import "" "task.return" (func $ret (param i32)))
        (func (export "double") (param i32) (result i32)
          (if (i32.eqz (local.get 0)) (then unreachable))
          (call $ret (i32.mul (local.get 0) (i32.const 2)))
          (i32.const 0))
        (func (export "cb") (param i32 i32 i32) (result i32) unreachable))
      (core instance $i (instantiate $m
        (with "" (instance (export "task.return" (func $ret))))))
      (type $t (func async (param "x" u32) (result u32)))
      (func (export "double") (type $t)
        (canon lift (core func $i "double") async (callback (core func $i "cb")))))
    """.

compile(Wat) -> compile(Wat, #{}).
compile(Wat, Opts) ->
    {ok, Mod} = wasmtime:compile({wat, Wat}, Opts),
    Mod.

instance(Mod) -> instance(Mod, #{}).
instance(Mod, Opts) ->
    {ok, Inst} = wasmtime:instantiate(Mod, Opts),
    Inst.

async_export(_) ->
    Inst = instance(compile(double())),
    {ok, 42} = wasmtime:call(Inst, ~"double", [21]),
    {ok, 4} = wasmtime:call(Inst, ~"double", [2]),
    ok.

async_export_trap(_) ->
    Inst = instance(compile(double())),
    {error, #{class := trap, trace := [_ | _]}} = wasmtime:call(Inst, ~"double", [0]),
    {error, #{class := call}} = wasmtime:call(Inst, ~"double", [1]),
    ok.

%% The guest calls a host function declared `async`, lowered synchronously.
async_import(_) ->
    Mod = compile(
        ~"""
    (component
      (type $f (func async (param "x" u32) (result u32)))
      (import "twice" (func $twice (type $f)))
      (core func $twice-core (canon lower (func $twice)))
      (core func $ret (canon task.return (result u32)))
      (core module $m
        (import "" "twice" (func $twice (param i32) (result i32)))
        (import "" "task.return" (func $ret (param i32)))
        (func (export "go") (param i32) (result i32)
          (call $ret (call $twice (local.get 0)))
          (i32.const 0))
        (func (export "cb") (param i32 i32 i32) (result i32) unreachable))
      (core instance $i (instantiate $m (with "" (instance
        (export "twice" (func $twice-core))
        (export "task.return" (func $ret))))))
      (func (export "go") (type $f)
        (canon lift (core func $i "go") async (callback (core func $i "cb")))))
    """
    ),
    Twice = fun(_Inst, [X]) -> {ok, [X * 2]} end,
    Inst = instance(Mod, #{imports => #{{~"", ~"twice"} => Twice}}),
    {ok, 14} = wasmtime:call(Inst, ~"go", [7]),
    ok.

async_precompiled(_) ->
    {ok, Bin} = wasmtime:serialize(compile(double())),
    {ok, Mod} = wasmtime:deserialize(Bin),
    {ok, 6} = wasmtime:call(instance(Mod), ~"double", [3]),
    ok.

%% Each concurrent call needs a stack from the pool.
pooled_calls(_) ->
    Mod = compile(double(), #{allocator => pooling, pooling => #{instances => 8}}),
    Self = self(),
    Pids = [
        spawn_link(fun() ->
            Inst = instance(Mod),
            [{ok, 2} = wasmtime:call(Inst, ~"double", [1]) || _ <- lists:seq(1, 50)],
            ok = wasmtime:destroy(Inst),
            Self ! {done, self()}
        end)
     || _ <- lists:seq(1, 8)
    ],
    [
        receive
            {done, P} -> ok
        after 10000 -> ct:fail(timeout)
        end
     || P <- Pids
    ],
    ok.

%% Turning reference types off turns component async off with it, instead of
%% asking Wasmtime for an engine it cannot build.
reference_types_off(_) ->
    {error, #{class := compile}} =
        wasmtime:compile({wat, double()}, #{proposals => #{reference_types => false, gc => false}}),
    ok.

%% ------------------------------------------------------- what cannot cross

%% A synchronous export returning the readable end of a stream it makes.
stream_export(Result) ->
    iolist_to_binary([
        ~"""
        (component
          (type $s (stream u8))
          (core func $new (canon stream.new $s))
          (core module $m
            (import "" "new" (func $new (result i64)))
            (func (export "f") (result i32) (i32.wrap_i64 (call $new))))
          (core instance $i (instantiate $m
            (with "" (instance (export "new" (func $new))))))
        """,
        Result,
        ")"
    ]).

stream_result_refused(_) ->
    Wat = stream_export(~"(func (export \"f\") (result $s) (canon lift (core func $i \"f\")))"),
    Inst = instance(compile(Wat)),
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"f", []),
    %% refused before the guest ran: the instance still answers
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"f", []),
    ok.

nested_result_refused(_) ->
    Mod = compile(
        ~"""
    (component
      (type $s (stream u8))
      (type $r (list (option (tuple u32 $s))))
      (core module $m
        (memory (export "mem") 1)
        (func (export "f") (result i32) (i32.const 0)))
      (core instance $i (instantiate $m))
      (func (export "f") (result $r)
        (canon lift (core func $i "f") (memory (core memory $i "mem")))))
    """
    ),
    {error, #{class := call, kind := badarg}} = wasmtime:call(instance(Mod), ~"f", []),
    ok.

stream_param_refused(_) ->
    Mod = compile(
        ~"""
    (component
      (type $s (stream u8))
      (core module $m (func (export "f") (param i32)))
      (core instance $i (instantiate $m))
      (func (export "f") (param "s" $s) (canon lift (core func $i "f"))))
    """
    ),
    {error, #{class := call, kind := badarg}} = wasmtime:call(instance(Mod), ~"f", [1]),
    ok.

host_import_stream_refused(_) ->
    Mod = compile(
        ~"""
    (component
      (type $s (stream u8))
      (import "take" (func $take (param "s" $s)))
      (core func $take-core (canon lower (func $take)))
      (core module $m (import "" "take" (func (param i32))))
      (core instance (instantiate $m (with "" (instance
        (export "take" (func $take-core)))))))
    """
    ),
    Take = fun(_Inst, [_]) -> {ok, []} end,
    {error, #{class := link, kind := badarg}} =
        wasmtime:instantiate(Mod, #{imports => #{{~"", ~"take"} => Take}}),
    ok.

%% ------------------------------------------------------- stopping a wait

%% A guest waiting on a peer that never answers, and the peer's socket.
blocked_guest(Config) ->
    {ok, L} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(L),
    Dir = string:replace(?config(data_dir, Config), "component_async_SUITE", "component_SUITE"),
    {ok, Bin} = file:read_file(
        filename:join(unicode:characters_to_list(Dir), "net.component.wasm")
    ),
    {ok, Mod} = wasmtime:compile(Bin),
    Inst = instance(Mod, #{
        wasi => #{network => all, args => ["net", "tcp", "127.0.0.1:" ++ integer_to_list(Port)]}
    }),
    {L, Inst}.

%% The peer sees the guest's socket close once the instance is destroyed.
interrupt_waiting_guest(Config) ->
    {L, Inst} = blocked_guest(Config),
    {error, #{kind := timeout}} = wasmtime:run(Inst, #{timeout => 200}),
    %% the worker is free again: this answers instead of queueing forever
    {error, #{class := call}} = wasmtime:run(Inst, #{timeout => 2000}),
    {ok, S} = gen_tcp:accept(L, 2000),
    ok = wasmtime:destroy(Inst),
    {ok, _} = gen_tcp:recv(S, 0, 2000),
    {error, closed} = gen_tcp:recv(S, 0, 2000),
    ok = gen_tcp:close(L).

caller_death_frees_waiting_guest(Config) ->
    {L, Inst} = blocked_guest(Config),
    {Pid, Ref} = spawn_monitor(fun() -> wasmtime:run(Inst) end),
    {ok, S} = gen_tcp:accept(L, 2000),
    {ok, _} = gen_tcp:recv(S, 0, 2000),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, killed} -> ok
    end,
    {error, #{class := call}} = wasmtime:run(Inst, #{timeout => 2000}),
    ok = wasmtime:destroy(Inst),
    {error, closed} = gen_tcp:recv(S, 0, 2000),
    ok = gen_tcp:close(L).
