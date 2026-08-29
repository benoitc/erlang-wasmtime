%% WASI preview 1: arguments, environment, directories and stdio.
-module(wasmtime_wasi_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(wasmtime_test, [compile/1, instance/2, wasi_argv_wat/0, stdio_wat/0, collect/2]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    wasi_args/1,
    wasi_env/1,
    wasi_stdin_file/1,
    wasi_stderr_file/1,
    wasi_write_dir/1,
    wasi_read_dir_refuses_write/1,
    wasi_no_wasi_no_imports/1,
    wasi_stdin_binary/1,
    wasi_capture_output/1,
    wasi_capture_limit/1,
    wasi_inherit_args_env/1,
    wasi_read_output_while_running/1,
    wasi_stdin_stream/1,
    wasi_stdin_stream_blocked/1,
    wasi_stdin_stream_other_fds/1,
    wasi_stdout_stream/1
]).

all() ->
    [{group, G} || {G, _, _} <- groups()].

groups() ->
    [
        {wasi, [], [
            wasi_args,
            wasi_env,
            wasi_stdin_file,
            wasi_stderr_file,
            wasi_write_dir,
            wasi_read_dir_refuses_write,
            wasi_no_wasi_no_imports
        ]},
        {wasi_stdio, [], [
            wasi_stdin_binary,
            wasi_capture_output,
            wasi_capture_limit,
            wasi_inherit_args_env,
            wasi_read_output_while_running,
            wasi_stdin_stream,
            wasi_stdin_stream_blocked,
            wasi_stdin_stream_other_fds,
            wasi_stdout_stream
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat, wasi], Config).

end_per_suite(_) -> ok.

wasi_args(Config) ->
    Out = filename:join(?config(priv_dir, Config), "args.txt"),
    Inst = instance(wasi_argv_wat(), #{
        wasi => #{args => [~"prog", "second", ~"third arg"], stdout => {file, Out}}
    }),
    {ok, []} = wasmtime:call(Inst, ~"args", []),
    {ok, ~"prog\nsecond\nthird arg\n"} = file:read_file(Out),
    ok.

wasi_env(Config) ->
    Out = filename:join(?config(priv_dir, Config), "env.txt"),
    Inst = instance(wasi_argv_wat(), #{
        wasi => #{env => [{~"A", ~"1"}, {"B", "two"}], stdout => {file, Out}}
    }),
    {ok, []} = wasmtime:call(Inst, ~"env", []),
    {ok, ~"A=1\nB=two\n"} = file:read_file(Out),
    %% without env nothing is inherited from the VM
    Out2 = filename:join(?config(priv_dir, Config), "env2.txt"),
    Inst2 = instance(wasi_argv_wat(), #{wasi => #{stdout => {file, Out2}}}),
    {ok, []} = wasmtime:call(Inst2, ~"env", []),
    {ok, <<>>} = file:read_file(Out2),
    ok.

wasi_stdin_file(Config) ->
    In = filename:join(?config(priv_dir, Config), "in.txt"),
    Err = filename:join(?config(priv_dir, Config), "err.txt"),
    ok = file:write_file(In, ~"from stdin"),
    Inst = instance(wasi_argv_wat(), #{wasi => #{stdin => {file, In}, stderr => {file, Err}}}),
    {ok, [10]} = wasmtime:call(Inst, ~"cat", []),
    {ok, ~"from stdin"} = file:read_file(Err),
    %% stdin none reads end of file
    Inst2 = instance(wasi_argv_wat(), #{wasi => #{}}),
    {ok, [0]} = wasmtime:call(Inst2, ~"cat", []),
    ok.

wasi_stderr_file(Config) ->
    Err = filename:join(?config(priv_dir, Config), "stderr.txt"),
    In = filename:join(?config(priv_dir, Config), "in2.txt"),
    ok = file:write_file(In, ~"x"),
    Inst = instance(wasi_argv_wat(), #{wasi => #{stdin => {file, In}, stderr => {file, Err}}}),
    {ok, [1]} = wasmtime:call(Inst, ~"cat", []),
    {ok, ~"x"} = file:read_file(Err),
    ok.

wasi_write_dir(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "w"),
    ok = filelib:ensure_path(Dir),
    Inst = instance(wasi_argv_wat(), #{wasi => #{dirs => [{~"/w", Dir, write}]}}),
    {ok, [0]} = wasmtime:call(Inst, ~"create", []),
    true = filelib:is_file(filename:join(Dir, "new.txt")),
    ok.

wasi_read_dir_refuses_write(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "r"),
    ok = filelib:ensure_path(Dir),
    Inst = instance(wasi_argv_wat(), #{wasi => #{dirs => [{~"/r", Dir, read}]}}),
    {ok, [Errno]} = wasmtime:call(Inst, ~"create", []),
    ?assertNotEqual(0, Errno),
    false = filelib:is_file(filename:join(Dir, "new.txt")),
    ok.

wasi_no_wasi_no_imports(_) ->
    Mod = compile(wasi_argv_wat()),
    {error, #{class := link, message := Msg}} = wasmtime:instantiate(Mod),
    ?assertMatch({_, _}, binary:match(Msg, ~"wasi_snapshot_preview1")),
    %% a wasi option that is not a map is rejected in Erlang
    ?assertError(function_clause, wasmtime:instantiate(Mod, #{wasi => yes})),
    ok.

%% ---------------------------------------------------------------- limits

wasi_stdin_binary(_) ->
    Inst = instance(stdio_wat(), #{
        wasi => #{stdin => {binary, ~"from a binary"}, stdout => capture, stderr => capture}
    }),
    {ok, [13]} = wasmtime:call(Inst, ~"cat", []),
    {ok, {~"from a binary", ~"err", {0, 0}}} = wasmtime:read_output(Inst),
    %% read_output empties the buffers
    {ok, {<<>>, <<>>, {0, 0}}} = wasmtime:read_output(Inst),
    %% stdin was consumed
    {ok, [0]} = wasmtime:call(Inst, ~"cat", []),
    ok.

wasi_capture_output(_) ->
    Inst = instance(stdio_wat(), #{wasi => #{stdout => capture}}),
    {ok, []} = wasmtime:call(Inst, ~"spam", [3]),
    {ok, {~"012345678901234567890123456789", <<>>, {0, 0}}} = wasmtime:read_output(Inst),
    %% output accumulates across calls until read
    {ok, []} = wasmtime:call(Inst, ~"spam", [1]),
    {ok, []} = wasmtime:call(Inst, ~"spam", [1]),
    {ok, {~"01234567890123456789", <<>>, _}} = wasmtime:read_output(Inst),
    %% nothing captured without the option
    Quiet = instance(stdio_wat(), #{wasi => #{}}),
    {ok, []} = wasmtime:call(Quiet, ~"spam", [3]),
    {ok, {<<>>, <<>>, {0, 0}}} = wasmtime:read_output(Quiet),
    ok.

wasi_capture_limit(_) ->
    Inst = instance(stdio_wat(), #{wasi => #{stdout => capture, output_limit => 25}}),
    {ok, []} = wasmtime:call(Inst, ~"spam", [10]),
    {ok, {Kept, <<>>, {75, 0}}} = wasmtime:read_output(Inst),
    25 = byte_size(Kept),
    ok.

wasi_inherit_args_env(_) ->
    Own = instance(stdio_wat(), #{wasi => #{args => [~"a", ~"b"], env => [{~"K", ~"V"}]}}),
    {ok, [2]} = wasmtime:call(Own, ~"argc", []),
    {ok, [1]} = wasmtime:call(Own, ~"envc", []),
    None = instance(stdio_wat(), #{wasi => #{}}),
    {ok, [0]} = wasmtime:call(None, ~"argc", []),
    {ok, [0]} = wasmtime:call(None, ~"envc", []),
    Inherited = instance(stdio_wat(), #{wasi => #{args => inherit, env => inherit}}),
    %% argv reaches a dynamically loaded library only where the platform
    %% hands it out (glibc, macOS); FreeBSD gives an empty list
    {ok, [Argc]} = wasmtime:call(Inherited, ~"argc", []),
    ?assert(Argc >= 0),
    {ok, [Envc]} = wasmtime:call(Inherited, ~"envc", []),
    ?assert(Envc >= 1),
    ok.

wasi_read_output_while_running(_) ->
    %% a slow guest's output can be drained while it runs
    Slow =
        ~"""
        (module
          (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
          (import "env" "pause" (func $pause))
          (memory (export "memory") 1)
          (data (i32.const 60) "tick")
          (func (export "run")
            (i32.store (i32.const 0) (i32.const 60))
            (i32.store (i32.const 4) (i32.const 4))
            (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 12)))
            (call $pause)
            (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 12)))))
        """,
    Self = self(),
    Pause = fun(Ctx, []) ->
        %% inside the host call the guest is parked: read what it wrote so far
        Self ! {mid, wasmtime:read_output(Ctx)},
        {ok, []}
    end,
    Inst = instance(Slow, #{wasi => #{stdout => capture}, imports => #{{~"env", ~"pause"} => Pause}}),
    {ok, []} = wasmtime:call(Inst, ~"run", []),
    receive
        {mid, {ok, {~"tick", <<>>, _}}} -> ok
    after 1000 -> ct:fail(no_mid)
    end,
    {ok, {~"tick", <<>>, _}} = wasmtime:read_output(Inst),
    ok.

%% ------------------------------------------------------------------- api

wasi_stdin_stream(_) ->
    Inst = instance(stdio_wat(), #{wasi => #{stdin => stream, stdout => stream, stderr => capture}}),
    ok = wasmtime:send(Inst, ~"ab"),
    ok = wasmtime:send(Inst, ~"cd"),
    %% stdin is a byte stream: one read takes both chunks
    {ok, [4]} = wasmtime:call(Inst, ~"cat", []),
    [~"abcd"] = collect(stdout, 1),
    {ok, {<<>>, ~"err", {0, 0}}} = wasmtime:read_output(Inst),
    ok = wasmtime:close(Inst),
    %% end of file once closed and drained
    {ok, [0]} = wasmtime:call(Inst, ~"cat", []),
    {ok, [0]} = wasmtime:call(Inst, ~"cat", []),
    ok.

wasi_stdin_stream_blocked(_) ->
    Inst = instance(stdio_wat(), #{wasi => #{stdin => stream, stdout => stream}}),
    %% a read with nothing queued waits for send/2
    {ok, R} = wasmtime:call_async(Inst, ~"cat", []),
    timer:sleep(50),
    ok = wasmtime:send(Inst, ~"late"),
    {ok, [4]} = wasmtime:await(Inst, R),
    [~"late"] = collect(stdout, 1),
    %% and can be interrupted
    {error, #{kind := timeout}} = wasmtime:call(Inst, ~"cat", [], #{timeout => 100}),
    ok = wasmtime:send(Inst, ~"x"),
    {ok, [1]} = wasmtime:call(Inst, ~"cat", []),
    ok.

wasi_stdin_stream_other_fds(_) ->
    %% fd_read on anything but 0 still goes to Wasmtime: same answer with
    %% and without the override
    Wat =
        ~"""
    (module
      (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
      (memory (export "memory") 1)
      (func (export "read_fd") (param i32) (result i32)
        (i32.store (i32.const 0) (i32.const 100))
        (i32.store (i32.const 4) (i32.const 10))
        (call $fd_read (local.get 0) (i32.const 0) (i32.const 1) (i32.const 8)))
      (func (export "read_bad") (result i32)
        (call $fd_read (i32.const 0) (i32.const 70000) (i32.const 1) (i32.const 8))))
    """,
    Plain = instance(Wat, #{wasi => #{}}),
    Streamed = instance(Wat, #{wasi => #{stdin => stream}}),
    {ok, [Errno]} = wasmtime:call(Plain, ~"read_fd", [1]),
    ?assert(Errno > 0),
    {ok, [Errno]} = wasmtime:call(Streamed, ~"read_fd", [1]),
    {ok, [Errno]} = wasmtime:call(Streamed, ~"read_fd", [99]),
    %% bad iovec pointers answer EFAULT instead of trapping
    {ok, [21]} = wasmtime:call(Streamed, ~"read_bad", []),
    ok.

wasi_stdout_stream(_) ->
    Self = self(),
    Collector = spawn_link(fun Loop() ->
        receive
            {wasmtime_stream, _, K, B} ->
                Self ! {K, B},
                Loop()
        end
    end),
    Inst = instance(stdio_wat(), #{
        wasi => #{stdin => {binary, ~"in"}, stdout => stream, stderr => stream},
        stream => Collector
    }),
    {ok, []} = wasmtime:call(Inst, ~"spam", [2]),
    %% one message per write, as it happens
    receive
        {stdout, ~"0123456789"} -> ok
    after 2000 -> error(no_stdout)
    end,
    receive
        {stdout, ~"0123456789"} -> ok
    after 2000 -> error(no_stdout)
    end,
    {ok, [2]} = wasmtime:call(Inst, ~"cat", []),
    receive
        {stdout, ~"in"} -> ok
    after 2000 -> error(no_stdout)
    end,
    receive
        {stderr, ~"err"} -> ok
    after 2000 -> error(no_stderr)
    end,
    %% nothing was captured
    {ok, {<<>>, <<>>, {0, 0}}} = wasmtime:read_output(Inst),
    ok.
