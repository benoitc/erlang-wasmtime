%% wasmtime_instance_worker: one instance in a process, a deadline per
%% request, fresh or reused between requests. The cases follow erlang_wasm's
%% wasm_worker_SUITE where the behaviour is shared.
-module(wasmtime_worker_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    runs_a_request/1,
    state_does_not_leak_between_requests/1,
    reuse_policy_keeps_state/1,
    infinite_loop_is_bounded_by_timeout/1,
    infinite_loop_is_bounded_by_fuel/1,
    a_queued_request_keeps_its_deadline/1,
    memory_growth_is_bounded_per_instance/1,
    trap_leaves_the_worker_usable/1,
    crashing_host_function_becomes_an_error/1,
    a_hanging_host_function_kills_the_worker/1,
    killing_a_worker_does_not_disturb_others/1,
    a_gone_worker_answers_with_a_value/1,
    a_failed_start_stops_the_worker/1,
    limits_are_validated/1,
    worker_is_labelled/1,
    stop_destroys_the_instance/1,
    wasi_through_options/1
]).

all() ->
    [
        runs_a_request,
        state_does_not_leak_between_requests,
        reuse_policy_keeps_state,
        infinite_loop_is_bounded_by_timeout,
        infinite_loop_is_bounded_by_fuel,
        a_queued_request_keeps_its_deadline,
        memory_growth_is_bounded_per_instance,
        trap_leaves_the_worker_usable,
        crashing_host_function_becomes_an_error,
        a_hanging_host_function_kills_the_worker,
        killing_a_worker_does_not_disturb_others,
        a_gone_worker_answers_with_a_value,
        a_failed_start_stops_the_worker,
        limits_are_validated,
        worker_is_labelled,
        stop_destroys_the_instance,
        wasi_through_options
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat], Config).

end_per_suite(_) -> ok.

-define(W, wasmtime_instance_worker).

module() ->
    wasmtime_test:compile(
        ~"""
        (module
          (import "env" "host" (func $host (param i32) (result i32)))
          (memory (export "memory") 1 64)
          (global $n (mut i32) (i32.const 0))
          (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
          (func (export "bump") (result i32)
            (global.set $n (i32.add (global.get $n) (i32.const 1))) global.get $n)
          (func (export "spin") (loop br 0))
          (func (export "boom") unreachable)
          (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
          (func (export "host") (param i32) (result i32) local.get 0 call $host))
        """
    ).

imports() ->
    #{
        {~"env", ~"host"} => fun
            (_Ctx, [0]) -> error(crashed);
            (_Ctx, [1]) -> timer:sleep(infinity);
            (_Ctx, [N]) -> {ok, [N * 2]}
        end
    }.

start(Opts) ->
    {ok, W} = ?W:start_link(module(), Opts#{imports => imports()}),
    W.

runs_a_request(_) ->
    W = start(#{}),
    {ok, [3]} = ?W:call(W, ~"add", [1, 2]),
    {ok, [42]} = ?W:call(W, ~"host", [21]),
    {ok, #{served := 2, isolation := fresh}} = ?W:info(W),
    {error, unknown_call} = gen_server:call(W, something_else),
    ok = ?W:stop(W).

state_does_not_leak_between_requests(_) ->
    W = start(#{}),
    {ok, [1]} = ?W:call(W, ~"bump", []),
    {ok, [1]} = ?W:call(W, ~"bump", []),
    ok = ?W:stop(W).

reuse_policy_keeps_state(_) ->
    W = start(#{isolation => reuse}),
    {ok, [1]} = ?W:call(W, ~"bump", []),
    {ok, [2]} = ?W:call(W, ~"bump", []),
    {ok, #{isolation := reuse}} = ?W:info(W),
    ok = ?W:stop(W).

%% The guest is interrupted on its own thread: the worker survives, under
%% both policies.
infinite_loop_is_bounded_by_timeout(_) ->
    [
        begin
            W = start(#{isolation => Isolation}),
            {error, #{kind := timeout}} = ?W:call(W, ~"spin", [], 50),
            true = is_process_alive(W),
            {ok, [3]} = ?W:call(W, ~"add", [1, 2]),
            ok = ?W:stop(W)
        end
     || Isolation <- [fresh, reuse]
    ],
    %% the instance's own limit applies when the request has no deadline
    W2 = start(#{limits => #{timeout => 50}}),
    {error, #{kind := timeout}} = ?W:call(W2, ~"spin", [], infinity),
    ok = ?W:stop(W2),
    %% call/3 takes its deadline from the application environment
    ok = application:set_env(erlang_wasmtime, worker_timeout, 50),
    W3 = start(#{}),
    try
        {error, #{kind := timeout}} = ?W:call(W3, ~"spin", [])
    after
        application:unset_env(erlang_wasmtime, worker_timeout)
    end,
    ok = ?W:stop(W3).

infinite_loop_is_bounded_by_fuel(_) ->
    {ok, Metered} = wasmtime:compile(
        {wat,
            ~"(module (func (export \"spin\") (loop br 0)) (func (export \"one\") (result i32) i32.const 1))"},
        #{fuel => true}
    ),
    {ok, W} = ?W:start_link(Metered, #{limits => #{fuel => 10_000}}),
    {error, #{kind := out_of_fuel}} = ?W:call(W, ~"spin", []),
    {ok, [1]} = ?W:call(W, ~"one", []),
    ok = ?W:stop(W).

%% The deadline covers the wait for the worker: a request that waited past
%% its own is not run.
a_queued_request_keeps_its_deadline(_) ->
    W = start(#{}),
    Self = self(),
    spawn_link(fun() -> Self ! {first, ?W:call(W, ~"spin", [], 300)} end),
    timer:sleep(50),
    {error, #{kind := timeout}} = ?W:call(W, ~"add", [1, 2], 100),
    receive
        {first, {error, #{kind := timeout}}} -> ok
    end,
    {ok, #{served := 1}} = ?W:info(W),
    ok = ?W:stop(W).

memory_growth_is_bounded_per_instance(_) ->
    W = start(#{limits => #{max_memory_pages => 4}}),
    {ok, [1]} = ?W:call(W, ~"grow", [3]),
    {ok, [-1]} = ?W:call(W, ~"grow", [4]),
    ok = ?W:stop(W).

trap_leaves_the_worker_usable(_) ->
    [
        begin
            W = start(#{isolation => Isolation}),
            {error, #{class := trap, kind := unreachable}} = ?W:call(W, ~"boom", []),
            {ok, [3]} = ?W:call(W, ~"add", [1, 2]),
            ok = ?W:stop(W)
        end
     || Isolation <- [fresh, reuse]
    ],
    ok.

crashing_host_function_becomes_an_error(_) ->
    W = start(#{}),
    {error, #{class := host}} = ?W:call(W, ~"host", [0]),
    true = is_process_alive(W),
    {ok, [4]} = ?W:call(W, ~"host", [2]),
    ok = ?W:stop(W).

%% A deadline cannot interrupt the worker's own host function: the caller
%% kills the worker a second after it.
a_hanging_host_function_kills_the_worker(_) ->
    process_flag(trap_exit, true),
    W = start(#{}),
    Mon = monitor(process, W),
    {error, #{kind := timeout}} = ?W:call(W, ~"host", [1], 50),
    receive
        {'DOWN', Mon, process, W, killed} -> ok
    end,
    receive
        {'EXIT', W, killed} -> ok
    end,
    process_flag(trap_exit, false),
    ok.

killing_a_worker_does_not_disturb_others(_) ->
    process_flag(trap_exit, true),
    A = start(#{isolation => reuse}),
    B = start(#{isolation => reuse}),
    {ok, [1]} = ?W:call(B, ~"bump", []),
    exit(A, kill),
    receive
        {'EXIT', A, killed} -> ok
    end,
    {ok, [2]} = ?W:call(B, ~"bump", []),
    ok = ?W:stop(B),
    process_flag(trap_exit, false),
    ok.

a_gone_worker_answers_with_a_value(_) ->
    W = start(#{}),
    ok = ?W:stop(W),
    {error, #{class := link, kind := no_worker}} = ?W:call(W, ~"add", [1, 2]),
    %% one that dies while the request runs
    process_flag(trap_exit, true),
    W2 = start(#{}),
    Self = self(),
    spawn_link(fun() -> Self ! {answer, ?W:call(W2, ~"spin", [], infinity)} end),
    timer:sleep(50),
    exit(W2, kill),
    receive
        {answer, {error, #{class := trap, kind := worker_died}}} -> ok
    end,
    process_flag(trap_exit, false),
    ok.

a_failed_start_stops_the_worker(_) ->
    process_flag(trap_exit, true),
    %% the import is missing
    {ok, W} = ?W:start_link(module(), #{}),
    receive
        {'EXIT', W, {instantiate_failed, #{class := link}}} -> ok
    end,
    process_flag(trap_exit, false),
    ok.

limits_are_validated(_) ->
    process_flag(trap_exit, true),
    [
        begin
            {ok, W} = ?W:start_link(module(), #{imports => imports(), limits => Limits}),
            receive
                {'EXIT', W, {instantiate_failed, #{kind := invalid_limits}}} -> ok
            end
        end
     || Limits <- [#{max_heap_words => 1024}, #{timeout => soon}, #{max_depth => 10}]
    ],
    process_flag(trap_exit, false),
    ok.

worker_is_labelled(_) ->
    W = start(#{name => billing}),
    {ok, #{name := billing}} = ?W:info(W),
    {wasmtime_instance_worker, billing} = proc_lib:get_label(W),
    undefined = whereis(billing),
    ok = ?W:stop(W).

stop_destroys_the_instance(_) ->
    Self = self(),
    Imports = (imports())#{
        {~"env", ~"host"} => fun(Ctx, [N]) ->
            Self ! {instance, Ctx},
            {ok, [N]}
        end
    },
    {ok, W} = ?W:start_link(module(), #{imports => Imports, isolation => reuse}),
    {ok, [7]} = ?W:call(W, ~"host", [7]),
    Inst =
        receive
            {instance, I} -> I
        end,
    ok = ?W:stop(W),
    {error, #{kind := stopped}} = wasmtime:call(Inst, ~"add", [1, 2]),
    ok.

%% `options` carries what erlang_wasm's worker has no key for.
wasi_through_options(Config) ->
    case wasmtime_test:needs([wasi], Config) of
        {skip, _} = Skip ->
            Skip;
        _ ->
            Mod = wasmtime_test:compile(
                ~"""
                (module
                  (import "wasi_snapshot_preview1" "fd_write"
                    (func $w (param i32 i32 i32 i32) (result i32)))
                  (memory (export "memory") 1)
                  (data (i32.const 8) "hi\n")
                  (func (export "say") (result i32)
                    (i32.store (i32.const 0) (i32.const 8))
                    (i32.store (i32.const 4) (i32.const 3))
                    (call $w (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 20))))
                """
            ),
            {ok, W} = ?W:start_link(Mod, #{options => #{wasi => #{stdout => none}}}),
            {ok, [0]} = ?W:call(W, ~"say", []),
            ok = ?W:stop(W)
    end.
