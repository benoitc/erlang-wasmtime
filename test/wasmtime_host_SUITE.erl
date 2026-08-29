%% Host functions: imports backed by Erlang funs, served by the caller or
%% by a dedicated process.
-module(wasmtime_host_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(wasmtime_test, [compile/1, instance/1, instance/2, host_wat/0, handler/1]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    imports_several_functions/1,
    imports_same_name_different_module/1,
    imports_extra_keys_ignored/1,
    imports_non_function_refused/1,
    imports_host_calls_other_instance/1,
    imports_called_many_times/1,
    imports_host_reads_and_writes_memory/1,
    imports_no_result_host/1,
    imports_multi_result_host/1,
    host_process_serves_calls/1,
    host_process_reentrancy_refused/1,
    host_process_gone/1
]).

all() ->
    [{group, G} || {G, _, _} <- groups()].

groups() ->
    [
        {imports, [parallel], [
            imports_several_functions,
            imports_same_name_different_module,
            imports_extra_keys_ignored,
            imports_non_function_refused,
            imports_host_calls_other_instance,
            imports_called_many_times,
            imports_host_reads_and_writes_memory,
            imports_no_result_host,
            imports_multi_result_host
        ]},
        {host_process, [parallel], [
            host_process_serves_calls,
            host_process_reentrancy_refused,
            host_process_gone
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat], Config).

end_per_suite(_) -> ok.

imports_several_functions(_) ->
    Wat =
        ~"""
        (module
          (import "math" "add" (func $add (param i32 i32) (result i32)))
          (import "math" "mul" (func $mul (param i32 i32) (result i32)))
          (import "io" "emit" (func $emit (param i32)))
          (func (export "run") (param i32 i32) (result i32)
            local.get 0 local.get 1 call $add
            local.get 0 local.get 1 call $mul
            call $add
            (call $emit (i32.const 99))))
        """,
    Self = self(),
    Inst = instance(Wat, #{
        imports => #{
            {~"math", ~"add"} => fun(_, [A, B]) -> {ok, [A + B]} end,
            {~"math", ~"mul"} => fun(_, [A, B]) -> {ok, [A * B]} end,
            {~"io", ~"emit"} => fun(_, [X]) ->
                Self ! {emit, X},
                {ok, []}
            end
        }
    }),
    %% (3+4) + (3*4) = 19; the result is left on the stack after emit
    {ok, [19]} = wasmtime:call(Inst, ~"run", [3, 4]),
    receive
        {emit, 99} -> ok
    after 1000 -> ct:fail(no_emit)
    end,
    ok.

imports_same_name_different_module(_) ->
    Wat =
        ~"""
        (module
          (import "a" "f" (func $af (result i32)))
          (import "b" "f" (func $bf (result i32)))
          (func (export "a") (result i32) call $af)
          (func (export "b") (result i32) call $bf))
        """,
    Inst = instance(Wat, #{
        imports => #{
            {~"a", ~"f"} => fun(_, []) -> {ok, [1]} end,
            {~"b", ~"f"} => fun(_, []) -> {ok, [2]} end
        }
    }),
    {ok, [1]} = wasmtime:call(Inst, ~"a", []),
    {ok, [2]} = wasmtime:call(Inst, ~"b", []),
    ok.

imports_extra_keys_ignored(_) ->
    Wat =
        ~"(module (import \"a\" \"f\" (func $f (result i32))) (func (export \"g\") (result i32) call $f))",
    Shared = #{
        {~"a", ~"f"} => fun(_, []) -> {ok, [1]} end,
        {~"unused", ~"x"} => fun(_, _) -> {ok, []} end
    },
    Inst = instance(Wat, #{imports => Shared}),
    {ok, [1]} = wasmtime:call(Inst, ~"g", []),
    ok.

imports_non_function_refused(_) ->
    Mod = compile(~"(module (import \"env\" \"mem\" (memory 1)))"),
    {error, #{class := link, kind := unsupported_import}} =
        wasmtime:instantiate(Mod, #{imports => #{{~"env", ~"mem"} => fun(_, _) -> {ok, []} end}}),
    Mod2 = compile(~"(module (import \"env\" \"g\" (global i32)))"),
    {error, #{class := link, kind := unsupported_import}} =
        wasmtime:instantiate(Mod2, #{imports => #{{~"env", ~"g"} => fun(_, _) -> {ok, []} end}}),
    ok.

imports_host_calls_other_instance(_) ->
    %% A host function may call into a different instance: the two do not
    %% share a thread, so nothing deadlocks.
    Inner = instance(
        ~"(module (func (export \"sq\") (param i32) (result i32) local.get 0 local.get 0 i32.mul))"
    ),
    Outer = instance(
        ~"(module (import \"env\" \"sq\" (func $sq (param i32) (result i32))) (func (export \"f\") (param i32) (result i32) local.get 0 call $sq i32.const 1 i32.add))",
        #{imports => #{{~"env", ~"sq"} => fun(_, [X]) -> wasmtime:call(Inner, ~"sq", [X]) end}}
    ),
    {ok, [26]} = wasmtime:call(Outer, ~"f", [5]),
    ok.

imports_called_many_times(_) ->
    Wat =
        ~"""
        (module
          (import "env" "tick" (func $tick (param i32) (result i32)))
          (func (export "loop") (param i32) (result i32) (local i32)
            (block
              (loop
                local.get 0 i32.eqz br_if 1
                local.get 1 call $tick local.set 1
                local.get 0 i32.const 1 i32.sub local.set 0
                br 0))
            local.get 1))
        """,
    Inst = instance(Wat, #{imports => #{{~"env", ~"tick"} => fun(_, [N]) -> {ok, [N + 1]} end}}),
    {ok, [10000]} = wasmtime:call(Inst, ~"loop", [10000]),
    ok.

imports_host_reads_and_writes_memory(_) ->
    Wat =
        ~"""
        (module
          (import "env" "upper" (func $upper (param i32 i32)))
          (memory (export "memory") 1)
          (data (i32.const 0) "hello")
          (func (export "run") (call $upper (i32.const 0) (i32.const 5))))
        """,
    Upper = fun(Ctx, [Ptr, Len]) ->
        {ok, S} = wasmtime:read_memory(Ctx, Ptr, Len),
        ok = wasmtime:write_memory(Ctx, Ptr, string:uppercase(S)),
        {ok, []}
    end,
    Inst = instance(Wat, #{imports => #{{~"env", ~"upper"} => Upper}}),
    {ok, []} = wasmtime:call(Inst, ~"run", []),
    {ok, ~"HELLO"} = wasmtime:read_memory(Inst, 0, 5),
    ok.

imports_no_result_host(_) ->
    Wat = ~"(module (import \"env\" \"f\" (func $f)) (func (export \"g\") call $f))",
    Inst = instance(Wat, #{imports => #{{~"env", ~"f"} => fun(_, []) -> {ok, []} end}}),
    {ok, []} = wasmtime:call(Inst, ~"g", []),
    Bad = instance(Wat, #{imports => #{{~"env", ~"f"} => fun(_, []) -> {ok, [1]} end}}),
    {error, #{class := host}} = wasmtime:call(Bad, ~"g", []),
    ok.

imports_multi_result_host(_) ->
    Wat =
        ~"""
        (module
          (import "env" "divmod" (func $divmod (param i32 i32) (result i32 i32)))
          (func (export "run") (param i32 i32) (result i32 i32)
            local.get 0 local.get 1 call $divmod))
        """,
    Inst = instance(Wat, #{
        imports => #{{~"env", ~"divmod"} => fun(_, [A, B]) -> {ok, [A div B, A rem B]} end}
    }),
    {ok, [3, 1]} = wasmtime:call(Inst, ~"run", [10, 3]),
    ok.

%% ------------------------------------------------------------------ wasi

host_process_serves_calls(_) ->
    Self = self(),
    Handler = spawn_link(fun() -> handler(Self) end),
    Twice = fun(_, [X]) ->
        Self ! {ran_in, self()},
        {ok, [X * 2]}
    end,
    {ok, Inst} = wasmtime:instantiate(compile(host_wat()), #{
        host => Handler, imports => #{{~"env", ~"twice"} => Twice}
    }),
    Handler ! {inst, Inst},
    {ok, [42]} = wasmtime:call(Inst, ~"run", [21]),
    receive
        {ran_in, Pid} -> Handler = Pid
    after 1000 -> ct:fail(not_served)
    end,
    receive
        {served, Handler} -> ok
    after 1000 -> ct:fail(no_ack)
    end,
    %% the caller never saw the host call message
    receive
        {wasmtime_host_call, _, _, _, _} = M -> ct:fail({leaked_to_caller, M})
    after 0 -> ok
    end,
    ignore = wasmtime:handle_host_call(Inst, something_else),
    Handler ! stop,
    ok.

host_process_reentrancy_refused(_) ->
    %% the handler calling the instance from inside a host fun is refused,
    %% the same as a caller would be
    Self = self(),
    Handler = spawn_link(fun() -> handler(Self) end),
    Twice = fun(Ctx, [X]) ->
        Self ! {inner, wasmtime:call(Ctx, ~"run", [1])},
        {ok, [X]}
    end,
    {ok, Inst} = wasmtime:instantiate(compile(host_wat()), #{
        host => Handler, imports => #{{~"env", ~"twice"} => Twice}
    }),
    Handler ! {inst, Inst},
    {ok, [5]} = wasmtime:call(Inst, ~"run", [5]),
    receive
        {inner, {error, #{kind := reentrant}}} -> ok
    after 1000 -> ct:fail(no_inner)
    end,
    Handler ! stop,
    ok.

host_process_gone(_) ->
    %% a dead handler fails the guest at once instead of waiting host_timeout
    Handler = spawn(fun() -> ok end),
    timer:sleep(20),
    {ok, Inst} = wasmtime:instantiate(compile(host_wat()), #{
        host => Handler,
        host_timeout => 60000,
        imports => #{{~"env", ~"twice"} => fun(_, [X]) -> {ok, [X]} end}
    }),
    T0 = erlang:monotonic_time(millisecond),
    {error, #{class := host, message := ~"host process is gone"}} = wasmtime:call(Inst, ~"run", [1]),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1000),
    ok.

%% ----------------------------------------------------------------- async
