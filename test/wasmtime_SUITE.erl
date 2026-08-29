-module(wasmtime_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    compile_errors/1,
    imports_exports/1,
    call_values/1,
    traps/1,
    missing_import_fails_link/1,
    host_call/1,
    host_error/1,
    host_timeout/1,
    host_exception/1,
    reference_types_refused/1,
    memory_access/1,
    memory_limit/1,
    instances_are_isolated/1,
    timeout_and_interrupt/1,
    interrupt_from_other_process/1,
    caller_death/1,
    concurrent_callers/1,
    wasi_stdout/1,
    wasi_no_dirs/1,
    wasi_dirs/1,
    wasi_exit/1,
    instance_gc/1
]).

all() ->
    [
        compile_errors,
        imports_exports,
        call_values,
        traps,
        missing_import_fails_link,
        host_call,
        host_error,
        host_timeout,
        host_exception,
        reference_types_refused,
        memory_access,
        memory_limit,
        instances_are_isolated,
        timeout_and_interrupt,
        interrupt_from_other_process,
        caller_death,
        concurrent_callers,
        wasi_stdout,
        wasi_no_dirs,
        wasi_dirs,
        wasi_exit,
        instance_gc
    ].

init_per_suite(Config) ->
    {ok, Mod} = wasmtime:compile({wat, basic_wat()}),
    [{basic, Mod} | Config].

end_per_suite(_) -> ok.

basic_wat() ->
    ~"""
    (module
      (import "env" "log" (func $log (param i32) (result i32)))
      (memory (export "memory") 1)
      (func (export "add") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.add)
      (func (export "add64") (param i64 i64) (result i64)
        local.get 0 local.get 1 i64.add)
      (func (export "half") (param f64) (result f64)
        local.get 0 f64.const 2 f64.div)
      (func (export "sqrt32") (param f32) (result f32)
        local.get 0 f32.sqrt)
      (func (export "swap") (param i32 i32) (result i32 i32)
        local.get 1 local.get 0)
      (func (export "twice") (param i32) (result i32)
        local.get 0 call $log)
      (func (export "loop") (loop br 0))
      (func (export "boom") unreachable)
      (func (export "div") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.div_s)
      (func $rec (export "recurse") (param i32) (result i32)
        local.get 0 call $rec)
      (func (export "grow") (param i32) (result i32)
        local.get 0 memory.grow)
      (func (export "store") (param i32 i32)
        local.get 0 local.get 1 i32.store)
      (func (export "load") (param i32) (result i32)
        local.get 0 i32.load))
    """.

instance(Config) -> instance(Config, #{}).
instance(Config, Opts) ->
    Log = fun(_Ctx, [X]) -> {ok, [X * 2]} end,
    Imports = maps:merge(#{{~"env", ~"log"} => Log}, maps:get(imports, Opts, #{})),
    {ok, Inst} = wasmtime:instantiate(?config(basic, Config), Opts#{imports => Imports}),
    Inst.

%% --------------------------------------------------------------- modules

compile_errors(_) ->
    {error, #{class := compile, message := _}} = wasmtime:compile({wat, ~"(module (func"}),
    {error, #{class := compile}} = wasmtime:compile(<<"not wasm">>),
    {error, #{class := compile}} =
        wasmtime:compile({wat, ~"(module (func (result i32) i64.const 1))"}),
    ok.

imports_exports(Config) ->
    Mod = ?config(basic, Config),
    [{~"env", ~"log", func}] = wasmtime:imports(Mod),
    Exports = wasmtime:exports(Mod),
    {~"memory", memory} = lists:keyfind(~"memory", 1, Exports),
    {~"add", func} = lists:keyfind(~"add", 1, Exports),
    ok.

%% ----------------------------------------------------------------- calls

call_values(Config) ->
    Inst = instance(Config),
    {ok, [42]} = wasmtime:call(Inst, ~"add", [40, 2]),
    {ok, [-1]} = wasmtime:call(Inst, ~"add", [16#FFFFFFFF, 0]),
    {ok, [1 bsl 40]} = wasmtime:call(Inst, ~"add64", [1 bsl 39, 1 bsl 39]),
    {ok, [1.5]} = wasmtime:call(Inst, ~"half", [3.0]),
    {ok, [2.0]} = wasmtime:call(Inst, ~"half", [4]),
    {ok, [nan]} = wasmtime:call(Inst, ~"half", [nan]),
    {ok, [infinity]} = wasmtime:call(Inst, ~"half", [infinity]),
    {ok, [neg_infinity]} = wasmtime:call(Inst, ~"half", [neg_infinity]),
    {ok, [3.0]} = wasmtime:call(Inst, ~"sqrt32", [9.0]),
    {ok, [2, 1]} = wasmtime:call(Inst, ~"swap", [1, 2]),
    {error, #{class := call, kind := badarity}} = wasmtime:call(Inst, ~"add", [1]),
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"add", [1, foo]),
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"add", [1 bsl 33, 0]),
    {error, #{class := call, kind := no_such_export}} = wasmtime:call(Inst, ~"nope", []),
    {error, #{class := call, kind := not_a_function}} = wasmtime:call(Inst, ~"memory", []),
    ok.

traps(Config) ->
    Inst = instance(Config),
    {error, #{class := trap, kind := unreachable, message := Msg}} = wasmtime:call(
        Inst, ~"boom", []
    ),
    ?assertMatch({_, _}, binary:match(Msg, ~"unreachable")),
    {error, #{class := trap, kind := integer_division_by_zero}} = wasmtime:call(Inst, ~"div", [1, 0]),
    {error, #{class := trap, kind := integer_overflow}} = wasmtime:call(Inst, ~"div", [
        -16#80000000, -1
    ]),
    {error, #{class := trap, kind := stack_overflow}} = wasmtime:call(Inst, ~"recurse", [1]),
    {error, #{class := trap, kind := memory_out_of_bounds}} = wasmtime:call(Inst, ~"load", [
        16#FFFFFFF0
    ]),
    %% the instance survives its traps
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2]),
    ok.

%% ------------------------------------------------------------ host calls

missing_import_fails_link(Config) ->
    {error, #{class := link, message := Msg}} = wasmtime:instantiate(?config(basic, Config)),
    ?assertMatch({_, _}, binary:match(Msg, ~"env::log")),
    ok.

host_call(Config) ->
    Self = self(),
    Log = fun(Ctx, [X]) ->
        Self ! {called_in, self()},
        %% memory is reachable while the guest waits on us
        ok = wasmtime:write_memory(Ctx, 0, <<X:32/little>>),
        {ok, [X + 1]}
    end,
    Inst = instance(Config, #{imports => #{{~"env", ~"log"} => Log}}),
    {ok, [42]} = wasmtime:call(Inst, ~"twice", [41]),
    receive
        {called_in, Pid} -> Pid = Self
    after 0 -> ct:fail(host_not_called)
    end,
    {ok, [41]} = wasmtime:call(Inst, ~"load", [0]),
    ok.

host_error(Config) ->
    Inst = instance(Config, #{imports => #{{~"env", ~"log"} => fun(_, _) -> {error, ~"nope"} end}}),
    {error, #{class := host, kind := host_error, message := ~"nope"}} = wasmtime:call(
        Inst, ~"twice", [1]
    ),
    Inst2 = instance(Config, #{
        imports => #{{~"env", ~"log"} => fun(_, _) -> {error, {some, term}} end}
    }),
    {error, #{class := host, message := ~"{some,term}"}} = wasmtime:call(Inst2, ~"twice", [1]),
    Inst3 = instance(Config, #{imports => #{{~"env", ~"log"} => fun(_, _) -> {ok, [1, 2]} end}}),
    {error, #{class := host, message := Msg}} = wasmtime:call(Inst3, ~"twice", [1]),
    ?assertMatch({_, _}, binary:match(Msg, ~"wrong number")),
    Inst4 = instance(Config, #{imports => #{{~"env", ~"log"} => fun(_, _) -> {ok, [1.5]} end}}),
    {error, #{class := host, message := Msg4}} = wasmtime:call(Inst4, ~"twice", [1]),
    ?assertMatch({_, _}, binary:match(Msg4, ~"wrong type")),
    ok.

host_exception(Config) ->
    Inst = instance(Config, #{imports => #{{~"env", ~"log"} => fun(_, _) -> error(kaboom) end}}),
    {error, #{class := host, message := Msg}} = wasmtime:call(Inst, ~"twice", [1]),
    ?assertMatch({_, _}, binary:match(Msg, ~"kaboom")),
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2]),
    ok.

host_timeout(Config) ->
    Inst = instance(Config, #{
        host_timeout => 100,
        imports => #{
            {~"env", ~"log"} => fun(_, _) ->
                timer:sleep(500),
                {ok, [0]}
            end
        }
    }),
    %% The Erlang fun still runs to completion in this process; the guest is
    %% the one that gives up waiting and traps.
    T0 = erlang:monotonic_time(millisecond),
    {error, #{class := host, message := ~"host function timed out"}} = wasmtime:call(
        Inst, ~"twice", [1]
    ),
    ?assert(erlang:monotonic_time(millisecond) - T0 >= 100),
    ok.

reference_types_refused(_) ->
    {ok, Mod} = wasmtime:compile(
        {wat,
            ~"""
        (module
          (import "env" "take_ref" (func (param externref)))
          (func (export "give_ref") (result externref) ref.null extern))
        """}
    ),
    {error, #{class := link, kind := unsupported_type}} =
        wasmtime:instantiate(Mod, #{
            imports => #{{~"env", ~"take_ref"} => fun(_, _) -> {ok, []} end}
        }),
    {ok, Mod2} = wasmtime:compile(
        {wat, ~"(module (func (export \"give_ref\") (result externref) ref.null extern))"}
    ),
    {ok, Inst} = wasmtime:instantiate(Mod2),
    {error, #{class := call, kind := unsupported_type}} = wasmtime:call(Inst, ~"give_ref", []),
    ok.

%% ---------------------------------------------------------------- memory

memory_access(Config) ->
    Inst = instance(Config),
    {ok, {1, 65536}} = wasmtime:memory_size(Inst),
    ok = wasmtime:write_memory(Inst, 100, <<1, 2, 3, 4>>),
    {ok, <<1, 2, 3, 4>>} = wasmtime:read_memory(Inst, 100, 4),
    {ok, [16#04030201]} = wasmtime:call(Inst, ~"load", [100]),
    {ok, []} = wasmtime:call(Inst, ~"store", [200, 16#11223344]),
    {ok, <<16#44, 16#33, 16#22, 16#11>>} = wasmtime:read_memory(Inst, 200, 4),
    {error, #{class := memory, kind := out_of_bounds}} = wasmtime:read_memory(Inst, 65536, 1),
    {error, #{class := memory, kind := out_of_bounds}} = wasmtime:write_memory(
        Inst, 65535, <<1, 2>>
    ),
    {ok, <<>>} = wasmtime:read_memory(Inst, 65536, 0),
    {ok, Mod} = wasmtime:compile({wat, ~"(module (func (export \"f\")))"}),
    {ok, NoMem} = wasmtime:instantiate(Mod),
    {error, #{class := memory, kind := no_memory}} = wasmtime:read_memory(NoMem, 0, 1),
    ok.

memory_limit(Config) ->
    Inst = instance(Config, #{memory_limit => 3 * 65536}),
    {ok, [1]} = wasmtime:call(Inst, ~"grow", [1]),
    {ok, [2]} = wasmtime:call(Inst, ~"grow", [1]),
    {ok, [-1]} = wasmtime:call(Inst, ~"grow", [1]),
    {ok, {3, _}} = wasmtime:memory_size(Inst),
    ok.

instances_are_isolated(Config) ->
    A = instance(Config),
    B = instance(Config),
    {ok, []} = wasmtime:call(A, ~"store", [0, 1]),
    {ok, []} = wasmtime:call(B, ~"store", [0, 2]),
    {ok, [1]} = wasmtime:call(A, ~"load", [0]),
    {ok, [2]} = wasmtime:call(B, ~"load", [0]),
    ok.

%% ------------------------------------------------------- interruption

timeout_and_interrupt(Config) ->
    Inst = instance(Config),
    T0 = erlang:monotonic_time(millisecond),
    {error, #{class := trap, kind := timeout}} = wasmtime:call(Inst, ~"loop", [], #{timeout => 100}),
    Elapsed = erlang:monotonic_time(millisecond) - T0,
    ?assert(Elapsed >= 100 andalso Elapsed < 1000, Elapsed),
    %% the late result was drained, the instance is idle and usable
    receive
        {wasmtime_result, _, _, _} = M -> ct:fail({stale, M})
    after 0 -> ok
    end,
    not_running = wasmtime:interrupt(Inst),
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2]),
    ok.

interrupt_from_other_process(Config) ->
    Inst = instance(Config),
    Self = self(),
    spawn_link(fun() ->
        timer:sleep(50),
        Self ! {interrupt, wasmtime:interrupt(Inst)}
    end),
    {error, #{class := trap, kind := interrupt}} = wasmtime:call(Inst, ~"loop", []),
    receive
        {interrupt, ok} -> ok
    after 1000 -> ct:fail(no_interrupt)
    end,
    ok.

caller_death(Config) ->
    Inst = instance(Config),
    Pid = spawn(fun() -> wasmtime:call(Inst, ~"loop", []) end),
    timer:sleep(50),
    exit(Pid, kill),
    %% the monitor ends the abandoned call; our call is queued behind it
    T0 = erlang:monotonic_time(millisecond),
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2], #{timeout => 2000}),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 1000),
    %% same while the abandoned caller is blocked inside a host function
    Slow = fun(_, _) -> timer:sleep(infinity) end,
    Inst2 = instance(Config, #{imports => #{{~"env", ~"log"} => Slow}}),
    Pid2 = spawn(fun() -> wasmtime:call(Inst2, ~"twice", [1]) end),
    timer:sleep(50),
    exit(Pid2, kill),
    {ok, [3]} = wasmtime:call(Inst2, ~"add", [1, 2], #{timeout => 2000}),
    ok.

concurrent_callers(Config) ->
    Inst = instance(Config),
    Self = self(),
    Pids = [
        spawn_link(fun() -> Self ! {self(), wasmtime:call(Inst, ~"twice", [N])} end)
     || N <- lists:seq(1, 20)
    ],
    Results = [
        receive
            {P, R} -> R
        after 5000 -> timeout
        end
     || P <- Pids
    ],
    Expected = [{ok, [N * 2]} || N <- lists:seq(1, 20)],
    Expected = Results,
    ok.

%% ------------------------------------------------------------------ wasi

wasi_wat() ->
    ~"""
    (module
      (import "wasi_snapshot_preview1" "fd_write"
        (func $fd_write (param i32 i32 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "path_open"
        (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "proc_exit" (func $proc_exit (param i32)))
      (memory (export "memory") 1)
      (data (i32.const 8) "hello\n")
      (data (i32.const 32) "f.txt")
      (func (export "_start")
        (i32.store (i32.const 0) (i32.const 8))
        (i32.store (i32.const 4) (i32.const 6))
        (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 20))))
      ;; open "f.txt" in the first preopen (fd 3); returns the errno
      (func (export "open") (result i32)
        (call $path_open (i32.const 3) (i32.const 0) (i32.const 32) (i32.const 5)
                         (i32.const 0) (i64.const 0) (i64.const 0) (i32.const 0) (i32.const 64)))
      (func (export "exit") (param i32) local.get 0 call $proc_exit))
    """.

wasi_stdout(Config) ->
    {ok, Mod} = wasmtime:compile({wat, wasi_wat()}),
    Out = filename:join(?config(priv_dir, Config), "stdout.txt"),
    {ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{stdout => {file, Out}}}),
    {ok, []} = wasmtime:call(Inst, ~"_start", []),
    {ok, ~"hello\n"} = file:read_file(Out),
    %% without wasi the imports are missing
    {error, #{class := link}} = wasmtime:instantiate(Mod),
    ok.

wasi_no_dirs(_) ->
    {ok, Mod} = wasmtime:compile({wat, wasi_wat()}),
    {ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{}}),
    %% fd 3 is not a preopen: EBADF (8)
    {ok, [8]} = wasmtime:call(Inst, ~"open", []),
    ok.

wasi_dirs(Config) ->
    {ok, Mod} = wasmtime:compile({wat, wasi_wat()}),
    Dir = filename:join(?config(priv_dir, Config), "data"),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "f.txt"), "x"),
    {ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{dirs => [{~"/data", Dir, read}]}}),
    {ok, [0]} = wasmtime:call(Inst, ~"open", []),
    ok.

wasi_exit(_) ->
    {ok, Mod} = wasmtime:compile({wat, wasi_wat()}),
    {ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{}}),
    {ok, []} = wasmtime:call(Inst, ~"exit", [0]),
    {error, #{class := exit, kind := exit, status := 3}} = wasmtime:call(Inst, ~"exit", [3]),
    ok.

%% --------------------------------------------------------------- lifetime

instance_gc(Config) ->
    %% Dropping every reference stops the thread and frees the store. Create
    %% many, let them be collected, and make sure a fresh one still works.
    lists:foreach(fun(_) -> _ = instance(Config) end, lists:seq(1, 200)),
    erlang:garbage_collect(),
    Inst = instance(Config),
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2]),
    ok.
