%% erlang_wasm's ways of running a WASI program: wasmtime_wasi,
%% wasmtime_wasi_preview1, preview2 and preview3, output sinks and the
%% random option.
-module(wasmtime_runner_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
%% a {Module, Function} host function
-export([nothing/2]).
-export([
    run_answers_status_and_output/1,
    imports_carry_the_configuration/1,
    output_to_a_pid_a_fun_and_a_device/1,
    sinks_leave_other_streams_alone/1,
    seeded_random/1,
    withheld_random/1,
    refused_options/1,
    run_command/1,
    run_command_mounts_and_status/1,
    run_command_0_3/1,
    run_command_refusals/1,
    root_imports_as_erlang_wasm_names_them/1,
    worker_counts_host_calls/1,
    worker_bounds_its_heap/1,
    script_worker_limits/1,
    module_bytes_are_capped/1,
    cache_caps/1
]).

all() ->
    [
        run_answers_status_and_output,
        imports_carry_the_configuration,
        output_to_a_pid_a_fun_and_a_device,
        sinks_leave_other_streams_alone,
        seeded_random,
        withheld_random,
        refused_options,
        run_command,
        run_command_mounts_and_status,
        run_command_0_3,
        run_command_refusals,
        root_imports_as_erlang_wasm_names_them,
        worker_counts_host_calls,
        worker_bounds_its_heap,
        script_worker_limits,
        module_bytes_are_capped,
        cache_caps
    ].

init_per_suite(Config) ->
    case wasmtime_test:needs([compiler, wat, wasi], Config) of
        {skip, _} = Skip ->
            Skip;
        _ ->
            {ok, _} = application:ensure_all_started(erlang_wasmtime),
            Config
    end.

end_per_suite(_) -> ok.

%% Writes "out" to stdout and "err" to stderr, then exits with the argument.
program() ->
    ~"""
    (module
      (import "wasi_snapshot_preview1" "fd_write" (func $w (param i32 i32 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "proc_exit" (func $x (param i32)))
      (import "erlang" "send" (func $send (param i32 i32)))
      (memory (export "memory") 1)
      (data (i32.const 32) "out\n")
      (data (i32.const 48) "err\n")
      (func $say (param $fd i32) (param $at i32)
        (i32.store (i32.const 0) (local.get $at))
        (i32.store (i32.const 4) (i32.const 4))
        (drop (call $w (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8))))
      (func (export "talk")
        (call $say (i32.const 1) (i32.const 32))
        (call $say (i32.const 2) (i32.const 48))
        (call $send (i32.const 32) (i32.const 3)))
      (func (export "_start")
        (call $say (i32.const 1) (i32.const 32))
        (call $say (i32.const 2) (i32.const 48))
        (call $x (i32.const 3))))
    """.

run_answers_status_and_output(_) ->
    Mod = wasmtime_test:compile(program()),
    {ok, 3, ~"out\n", ~"err\n"} = wasmtime_wasi:run(Mod, #{args => [~"p"]}),
    %% sinks given to run/2 are replaced by the capture
    {ok, 3, ~"out\n", _} = wasmtime_wasi:run(Mod, #{stdout => self()}),
    Returns = wasmtime_test:compile(~"(module (func (export \"_start\")))"),
    {ok, 0, <<>>, <<>>} = wasmtime_wasi:run(Returns),
    Traps = wasmtime_test:compile(~"(module (func (export \"_start\") unreachable))"),
    {error, #{class := trap, kind := unreachable}} = wasmtime_wasi:run(Traps, #{}),
    {ok, 3} = wasmtime_wasi_preview1:exit_code(#{class => trap, ctx => #{wasi_exit => 3}}),
    error = wasmtime_wasi_preview1:exit_code(#{class => trap, ctx => #{}}),
    ok.

imports_carry_the_configuration(_) ->
    Mod = wasmtime_test:compile(program()),
    Imports = wasmtime_wasi:imports(#{stdout => capture}),
    {ok, Inst} = wasmtime:instantiate(Mod, Imports, #{}),
    {error, #{ctx := #{wasi_exit := 3}}} = wasmtime:call(Inst, ~"_start", []),
    {ok, {~"out\n", <<>>, _}} = wasmtime:read_output(Inst),
    %% as instantiate/2, and merged with host functions
    Own = #{{~"wasi_snapshot_preview1", ~"proc_exit"} => fun(_, [_]) -> {ok, []} end},
    {ok, Mine} = wasmtime:instantiate(
        Mod, maps:merge(wasmtime_wasi_preview1:imports(#{}), Own)
    ),
    {ok, []} = wasmtime:call(Mine, ~"_start", []),
    {error, #{class := link, kind := badarg}} =
        wasmtime:instantiate(Mod, Imports, #{wasi => #{}}),
    ok.

output_to_a_pid_a_fun_and_a_device(Config) ->
    Mod = wasmtime_test:compile(program()),
    Self = self(),
    Fun = fun(Bytes) -> Self ! {errs, self(), Bytes} end,
    {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{wasi => #{stdout => Self, stderr => Fun}}),
    {ok, []} = wasmtime:call(Inst, ~"talk", []),
    %% both delivered by the time the call returns, by the caller
    receive
        {wasi_output, Self, ~"out\n"} -> ok
    after 0 -> ct:fail(no_stdout)
    end,
    receive
        {errs, Self, ~"err\n"} -> ok
    after 0 -> ct:fail(no_stderr)
    end,
    %% the process that calls is the one that delivers
    Other = spawn_monitor(fun() -> {ok, []} = wasmtime:call(Inst, ~"talk", []) end),
    {Pid, Mon} = Other,
    receive
        {wasi_output, Pid, ~"out\n"} -> ok
    after 5000 -> ct:fail(no_stdout_from_other)
    end,
    receive
        {'DOWN', Mon, _, _, normal} -> ok
    end,
    %% an io device, by name
    Path = filename:join(?config(priv_dir, Config), "device.txt"),
    {ok, File} = file:open(Path, [write]),
    true = register(runner_device, File),
    {ok, Dev} = wasmtime:instantiate(Mod, #{}, #{wasi => #{stdout => runner_device}}),
    {ok, []} = wasmtime:call(Dev, ~"talk", []),
    ok = file:close(File),
    {ok, ~"out\n"} = file:read_file(Path),
    %% a fun that raises loses the bytes and nothing else
    Crash = fun(_) -> error(boom) end,
    {ok, Bad} = wasmtime:instantiate(Mod, #{}, #{wasi => #{stdout => Crash}}),
    {ok, []} = wasmtime:call(Bad, ~"talk", []),
    ok.

sinks_leave_other_streams_alone(_) ->
    Mod = wasmtime_test:compile(program()),
    Self = self(),
    Stream = spawn_link(fun() ->
        receive
            Msg -> Self ! {streamed, Msg}
        end
    end),
    {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{
        wasi => #{stdout => Self}, stream => Stream
    }),
    {ok, []} = wasmtime:call(Inst, ~"talk", []),
    Ref = wasmtime:ref(Inst),
    receive
        {streamed, {wasmtime_stream, Ref, channel, ~"out"}} -> ok
    after 5000 -> ct:fail(no_channel)
    end,
    %% call_async delivers at await
    {ok, Req} = wasmtime:call_async(Inst, ~"talk", []),
    {ok, []} = wasmtime:await(Inst, Req),
    ok.

%% Fills 16 bytes with random and returns the errno and the first word.
random_wat() ->
    ~"""
    (module
      (import "wasi_snapshot_preview1" "random_get" (func $r (param i32 i32) (result i32)))
      (memory (export "memory") 2)
      (func (export "get") (param i32 i32) (result i32)
        local.get 0 local.get 1 call $r))
    """.

draw(Inst) ->
    {ok, [0]} = wasmtime:call(Inst, ~"get", [0, 16]),
    {ok, Bytes} = wasmtime:read_memory(Inst, 0, 16),
    Bytes.

seeded_random(_) ->
    Mod = wasmtime_test:compile(random_wat()),
    New = fun(Random) ->
        {ok, I} = wasmtime:instantiate(Mod, #{}, #{wasi => #{random => Random}}),
        I
    end,
    A = New({seed, 7}),
    First = draw(A),
    Second = draw(A),
    ?assertNotEqual(First, Second),
    B = New({seed, 7}),
    ?assertEqual(First, draw(B)),
    ?assertEqual(Second, draw(B)),
    ?assertNotEqual(First, draw(New({seed, 8}))),
    ?assertNotEqual(draw(New(strong)), draw(New(strong))),
    %% past the memory: refused before a byte is made
    {ok, [21]} = wasmtime:call(A, ~"get", [0, -1]),
    %% a large request is written whole
    {ok, [0]} = wasmtime:call(A, ~"get", [0, 131072]),
    ok.

withheld_random(_) ->
    Mod = wasmtime_test:compile(random_wat()),
    {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{wasi => #{random => none}}),
    {ok, [76]} = wasmtime:call(Inst, ~"get", [0, 16]),
    ok.

refused_options(_) ->
    Mod = wasmtime_test:compile(program()),
    Refused = fun(Key, Wasi) ->
        {error, #{class := link, kind := unsupported_option, ctx := #{keys := [Key]}}} =
            wasmtime:instantiate(Mod, #{}, #{wasi => Wasi})
    end,
    Refused(stdout, #{stdout => nobody_registered_this}),
    Refused(random, #{random => weak}),
    Refused(net, #{net => #{}}),
    ok.

component(Config, Name) ->
    Dir = string:replace(?config(data_dir, Config), "runner_SUITE", "component_SUITE"),
    {ok, Bin} = file:read_file(
        filename:join(unicode:characters_to_list(Dir), Name ++ ".component.wasm")
    ),
    Bin.

run_command(Config) ->
    needs_components(fun() ->
        Upper = component(Config, "realupper"),
        {ok, #{stdout := ~"LOUD", stderr := <<>>, exit_code := 0}} =
            wasmtime_wasi_preview2:run_command(Upper, ~"loud"),
        {ok, #{stdout := ~"a\n"}} = wasmtime_wasi_preview2:run_command(
            component(Config, "argv"), <<>>, #{args => [~"p", ~"a"]}
        ),
        {ok, #{stdout := ~"hi\n"}} = wasmtime_wasi_preview2:run_command(
            component(Config, "envvar"), <<>>, #{env => [{~"GREETING", ~"hi"}]}
        ),
        {ok, Prepared} = wasmtime_component:prepare(Upper),
        {ok, #{stdout := ~"AGAIN"}} =
            wasmtime_wasi_preview2:run_command(Prepared, ~"again", #{compile => true})
    end).

run_command_mounts_and_status(Config) ->
    needs_components(fun() ->
        {ok, #{exit_code := 1}} = wasmtime_wasi_preview2:run_command(
            component(Config, "exitcode"), <<>>, #{args => [~"x", ~"7"]}
        ),
        {error, #{class := malformed}} = wasmtime_wasi_preview2:run_command(~"junk", <<>>),
        Vectors = component(Config, "vectors"),
        {error, no_run_export} = wasmtime_wasi_preview2:run_command(Vectors, <<>>),
        %% a run that fails gives its cache claim back
        Resident = wasmtime_module_cache:resident(),
        {error, #{class := link}} =
            wasmtime_wasi_preview2:run_command(component(Config, "hostcall"), <<>>),
        Resident = wasmtime_module_cache:resident()
    end).

run_command_0_3(Config) ->
    case wasmtime:features() of
        #{wasi_p3 := true} ->
            Dir = string:replace(?config(data_dir, Config), "runner_SUITE", "wasi3_SUITE"),
            {ok, Bin} = file:read_file(
                filename:join(
                    unicode:characters_to_list(Dir), "p3_cli_hello_stdout.component.wasm"
                )
            ),
            {ok, #{stdout := ~"hello, world\n", exit_code := 0}} =
                wasmtime_wasi_preview3:run_command(Bin, <<>>, #{}),
            ok;
        #{wasi_p3 := false} ->
            {skip, "this library has no WASI 0.3"}
    end.

run_command_refusals(Config) ->
    needs_components(fun() ->
        Upper = component(Config, "realupper"),
        Refused = fun(Options) ->
            {error, #{class := link, kind := unsupported_option}} =
                wasmtime_wasi_preview2:run_command(Upper, <<>>, Options)
        end,
        Refused(#{stdout_limit => 1}),
        Refused(#{stdin_dir => ~"/"}),
        Refused(#{network => #{connect => [], max_sockets => 1}})
    end).

%% erlang_wasm names a component's own functions under "$root".
root_imports_as_erlang_wasm_names_them(Config) ->
    needs_components(fun() ->
        Self = self(),
        Post = fun([Msg]) ->
            Self ! {post, Msg},
            {ok, undefined}
        end,
        {ok, Inst} = wasmtime_component:instantiate(component(Config, "actor"), #{
            {~"$root", ~"post"} => Post, {~"$root", ~"note"} => fun([_]) -> undefined end
        }),
        {ok, undefined} = wasmtime_component:call(Inst, ~"handle", {[], none}, [{~"add", 2}]),
        receive
            {post, {~"added", 2}} -> ok
        after 0 -> ct:fail(no_post)
        end,
        ?assertEqual([~"handle"], wasmtime_component:exports(Inst)),
        ok = wasmtime_component:destroy(Inst)
    end).

%% Calls the host as many times as it is told.
caller_wat() ->
    ~"""
    (module
      (import "env" "f" (func $f))
      (func (export "call") (param $n i32)
        (loop $l
          (if (local.get $n)
            (then
              (call $f)
              (local.set $n (i32.sub (local.get $n) (i32.const 1)))
              (br $l))))))
    """.

worker_counts_host_calls(_) ->
    Mod = wasmtime_test:compile(caller_wat()),
    [
        begin
            {ok, W} = wasmtime_instance_worker:start_link(Mod, #{
                imports => Imports, limits => #{max_host_calls => 3}, isolation => reuse
            }),
            %% each request has the whole budget
            {ok, []} = wasmtime_instance_worker:call(W, ~"call", [3]),
            {ok, []} = wasmtime_instance_worker:call(W, ~"call", [3]),
            {error, #{class := exhaustion, kind := host_call_limit, ctx := #{limit := 3}}} =
                wasmtime_instance_worker:call(W, ~"call", [4]),
            ok = wasmtime_instance_worker:stop(W)
        end
     || Imports <- [
            #{{~"env", ~"f"} => fun(_, []) -> {ok, []} end},
            #{{~"env", ~"f"} => {?MODULE, nothing}}
        ]
    ],
    {error, #{class := link, kind := invalid_limits}} =
        wasmtime:instantiate(Mod, #{}, #{max_host_calls => 3}),
    {error, #{class := link, kind := invalid_limits}} =
        wasmtime:instantiate(Mod, #{}, #{max_heap_words => 1000}),
    ok.

nothing(_, []) -> {ok, []}.

worker_bounds_its_heap(_) ->
    Mod = wasmtime_test:compile(caller_wat()),
    Hog = fun(_, []) ->
        _ = length(lists:seq(1, 10_000_000)),
        {ok, []}
    end,
    process_flag(trap_exit, true),
    {ok, W} = wasmtime_instance_worker:start_link(Mod, #{
        imports => #{{~"env", ~"f"} => Hog}, limits => #{max_heap_words => 100_000}
    }),
    {error, #{class := trap, kind := worker_died}} =
        wasmtime_instance_worker:call(W, ~"call", [1]),
    ok.

script_worker_limits(_) ->
    {ok, W} = wasmtime_script_worker:start_link(wasmtime_test_adapter, #{
        limits => #{max_host_calls => 100, max_heap_words => 10_000_000}
    }),
    {ok, _} = wasmtime_script_worker:run(W, #{}),
    ok = wasmtime_script_worker:stop(W).

module_bytes_are_capped(_) ->
    ok = application:set_env(erlang_wasmtime, max_module_bytes, 16),
    try
        {error, #{class := exhaustion, kind := module_too_large, ctx := #{limit := 16}}} =
            wasmtime:compile({wat, caller_wat()}),
        {ok, _} = wasmtime:compile({wat, ~"(module)"})
    after
        ok = application:unset_env(erlang_wasmtime, max_module_bytes)
    end,
    ok.

%% The cache reads its caps when it starts.
cache_caps(_) ->
    Restart = fun() ->
        ok = application:stop(erlang_wasmtime),
        {ok, _} = application:ensure_all_started(erlang_wasmtime)
    end,
    Wat = fun(N) ->
        {wat, [~"(module (func (export \"f\") (result i32) i32.const ", integer_to_list(N), ~"))"]}
    end,
    Case = fun(Key, Value, Kind) ->
        ok = application:set_env(erlang_wasmtime, Key, Value),
        try
            Restart(),
            ok = new_second(),
            {ok, First} = wasmtime:load(Wat(101)),
            %% loading what is resident compiles nothing, so it counts nothing
            {ok, First} = wasmtime:load(Wat(101)),
            {error, #{class := exhaustion, kind := Kind}} = wasmtime:load(Wat(102))
        after
            ok = application:unset_env(erlang_wasmtime, Key),
            Restart()
        end
    end,
    Case(max_resident_module_bytes, 1, cache_full),
    Case(max_module_loads_per_second, 1, load_rate_exceeded),
    ok.

%% The load rate is counted per second: start at the beginning of one.
new_second() ->
    Now = erlang:monotonic_time(second),
    case erlang:monotonic_time(second) of
        Now ->
            timer:sleep(5),
            wait_second(Now);
        _ ->
            ok
    end.

wait_second(Then) ->
    case erlang:monotonic_time(second) of
        Then ->
            timer:sleep(5),
            wait_second(Then);
        _ ->
            ok
    end.

needs_components(Fun) ->
    case wasmtime:features() of
        #{components := true} ->
            _ = Fun(),
            ok;
        #{components := false} ->
            {skip, "this library has no component model"}
    end.
