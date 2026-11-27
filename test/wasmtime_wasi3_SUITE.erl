%% WASI 0.3 commands. The programs are Wasmtime's own self-checking test
%% programs (see the _data README): each exits 0 when every check passed and
%% traps otherwise. Each imports WASI 0.3 and, through its adapter, 0.2.
-module(wasmtime_wasi3_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    hello_stdout/1,
    args_env_and_stdio/1,
    stdin_binary/1,
    stdin_stream/1,
    monotonic_sleep/1,
    random/1,
    filesystem/1,
    read_only_dir/1,
    sockets/1,
    sockets_denied/1,
    http/1,
    http_denied/1,
    wall_clock_refused/1,
    interrupt_waiting_program/1,
    precompiled/1
]).

all() ->
    [
        hello_stdout,
        args_env_and_stdio,
        stdin_binary,
        stdin_stream,
        monotonic_sleep,
        random,
        filesystem,
        read_only_dir,
        sockets,
        sockets_denied,
        http,
        http_denied,
        wall_clock_refused,
        interrupt_waiting_program,
        precompiled
    ].

init_per_suite(Config0) ->
    case wasmtime_test:needs([compiler, wasi], Config0) of
        {skip, _} = Skip ->
            Skip;
        Config ->
            case wasmtime:features() of
                #{wasi_p3 := true} -> Config;
                #{wasi_p3 := false} -> {skip, "this library has no WASI 0.3"}
            end
    end.

end_per_suite(_) -> ok.

program(Config, Name) ->
    {ok, Bin} = file:read_file(
        filename:join(?config(data_dir, Config), Name ++ ".component.wasm")
    ),
    {ok, Mod} = wasmtime:compile(Bin),
    Mod.

%% Run a program with captured output.
run(Config, Name, Wasi) ->
    {ok, Inst} = wasmtime:instantiate(program(Config, Name), #{
        wasi => maps:merge(#{stdout => capture, stderr => capture}, Wasi)
    }),
    Result = wasmtime:run(Inst, #{timeout => 30000}),
    {ok, {Out, Err, _}} = wasmtime:read_output(Inst),
    {Result, Out, Err}.

%% What Wasmtime's own tests set: which errno conventions to expect.
errno_mode() ->
    case os:type() of
        {unix, darwin} -> {"ERRNO_MODE_MACOS", "1"};
        _ -> {"ERRNO_MODE_UNIX", "1"}
    end.

scratch(Config) ->
    Dir = filename:join(
        ?config(priv_dir, Config), integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    Dir.

hello_stdout(Config) ->
    {ok, ~"hello, world\n", _} = run(Config, "p3_cli_hello_stdout", #{}),
    ok.

args_env_and_stdio(Config) ->
    {ok, ~"hello stdout\n", ~"hello stderr\n"} = run(Config, "p3_cli", #{
        args => ["p3_cli.component", "."], env => [errno_mode()]
    }),
    %% a failed check is the program's error, not ours
    {{error, #{class := trap}}, _, _} = run(Config, "p3_cli", #{args => ["other"]}),
    ok.

stdin_binary(Config) ->
    {ok, _, _} = run(Config, "p3_cli_read_stdin", #{stdin => {binary, ~"hello!"}}),
    {{error, _}, _, _} = run(Config, "p3_cli_read_stdin", #{stdin => {binary, ~"other"}}),
    ok.

stdin_stream(Config) ->
    {ok, Inst} = wasmtime:instantiate(program(Config, "p3_cli_read_stdin"), #{
        wasi => #{stdin => stream}
    }),
    %% one chunk: the program expects the six bytes from its first read
    ok = wasmtime:send(Inst, ~"hello!"),
    ok = wasmtime:close(Inst),
    ok = wasmtime:run(Inst, #{timeout => 5000}).

monotonic_sleep(Config) ->
    {ok, _, _} = run(Config, "p3_clocks_sleep", #{}),
    {ok, _, _} = run(Config, "p3_clocks_sleep", #{clocks => monotonic}),
    ok.

random(Config) ->
    {ok, _, _} = run(Config, "p3_random_imports", #{}),
    ok.

filesystem(Config) ->
    {ok, _, _} = run(Config, "p3_filesystem_file_read_write", #{
        dirs => [{".", scratch(Config), write}], env => [errno_mode()]
    }),
    ok.

read_only_dir(Config) ->
    Dir = scratch(Config),
    {{error, _}, _, _} = run(Config, "p3_filesystem_file_read_write", #{
        dirs => [{".", Dir, read}], env => [errno_mode()]
    }),
    {ok, []} = file:list_dir(Dir),
    ok.

sockets(Config) ->
    {ok, _, _} = run(Config, "p3_sockets_tcp_sample_application", #{
        network => all, env => [errno_mode()]
    }),
    ok.

sockets_denied(Config) ->
    {{error, #{class := trap}}, _, _} =
        run(Config, "p3_sockets_tcp_sample_application", #{env => [errno_mode()]}),
    ok.

%% A server answering one request as the program expects.
http_server() ->
    {ok, L} = gen_tcp:listen(0, [
        binary, {active, false}, {ip, {127, 0, 0, 1}}, {packet, http_bin}
    ]),
    {ok, Port} = inet:port(L),
    Pid = spawn(fun() -> serve(L) end),
    ok = gen_tcp:controlling_process(L, Pid),
    {Pid, "127.0.0.1:" ++ integer_to_list(Port)}.

serve(L) ->
    case gen_tcp:accept(L) of
        {ok, S} ->
            {ok, {http_request, Method, {abs_path, Path}, _}} = gen_tcp:recv(S, 0, 5000),
            skip_headers(S),
            ok = inet:setopts(S, [{packet, raw}]),
            ok = gen_tcp:send(S, [
                "HTTP/1.1 200 OK\r\nx-wasmtime-test-method: ",
                atom_to_binary(Method),
                "\r\nx-wasmtime-test-uri: ",
                Path,
                "\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
            ]),
            ok = gen_tcp:close(S),
            serve(L);
        {error, _} ->
            ok
    end.

skip_headers(S) ->
    case gen_tcp:recv(S, 0, 5000) of
        {ok, http_eoh} -> ok;
        {ok, _} -> skip_headers(S)
    end.

http(Config) ->
    case wasmtime:features() of
        #{wasi_http := true} ->
            {Server, Addr} = http_server(),
            {ok, _, _} = run(Config, "p3_http_outbound_request_get", #{
                http => all, env => [{"HTTP_SERVER", Addr}]
            }),
            exit(Server, kill),
            ok;
        #{wasi_http := false} ->
            {skip, "this library has no wasi:http"}
    end.

%% `wasi:http` is linked only when granted.
http_denied(Config) ->
    {error, #{class := link}} = wasmtime:instantiate(
        program(Config, "p3_http_outbound_request_get"), #{wasi => #{}}
    ),
    ok.

%% None of Wasmtime's programs reads the 0.3 system clock alone.
wall_clock_refused(_) ->
    {ok, Mod} = wasmtime:compile(
        {wat,
            ~"""
        (component
          (import "wasi:clocks/system-clock@0.3.0" (instance $clock
            (type $instant' (record (field "seconds" s64) (field "nanoseconds" u32)))
            (export "instant" (type $instant (eq $instant')))
            (export "now" (func (result $instant)))))
          (core module $libc (memory (export "mem") 1))
          (core instance $libc (instantiate $libc))
          (core func $now (canon lower (func $clock "now")
            (memory (core memory $libc "mem"))))
          (core module $m
            (import "libc" "mem" (memory 1))
            (import "clock" "now" (func $now (param i32)))
            (func (export "seconds") (result i64)
              (call $now (i32.const 0))
              (i64.load (i32.const 0))))
          (core instance $i (instantiate $m
            (with "libc" (instance $libc))
            (with "clock" (instance (export "now" (func $now))))))
          (func (export "seconds") (result s64)
            (canon lift (core func $i "seconds"))))
        """}
    ),
    {ok, Open} = wasmtime:instantiate(Mod, #{wasi => #{}}),
    {ok, Seconds} = wasmtime:call(Open, ~"seconds", []),
    ?assert(Seconds > 1700000000),
    {ok, Refused} = wasmtime:instantiate(Mod, #{wasi => #{clocks => monotonic}}),
    {error, #{class := trap, kind := clock_refused}} = wasmtime:call(Refused, ~"seconds", []),
    ok.

%% A guest asleep for an hour on the 0.3 monotonic clock.
interrupt_waiting_program(_) ->
    {ok, Mod} = wasmtime:compile(
        {wat,
            ~"""
        (component
          (import "wasi:clocks/monotonic-clock@0.3.0" (instance $clock
            (export "wait-for" (func async (param "how-long" u64)))))
          (core func $wait (canon lower (func $clock "wait-for")))
          (core func $ret (canon task.return))
          (core module $m
            (import "" "wait" (func $wait (param i64)))
            (import "" "task.return" (func $ret))
            (func (export "nap") (result i32)
              (call $wait (i64.const 3600000000000))
              (call $ret)
              (i32.const 0))
            (func (export "cb") (param i32 i32 i32) (result i32) unreachable))
          (core instance $i (instantiate $m (with "" (instance
            (export "wait" (func $wait))
            (export "task.return" (func $ret))))))
          (type $t (func async))
          (func (export "nap") (type $t)
            (canon lift (core func $i "nap") async (callback (core func $i "cb")))))
        """}
    ),
    {ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{}}),
    {error, #{kind := timeout}} = wasmtime:call(Inst, ~"nap", [], #{timeout => 300}),
    %% the worker is free again: this answers instead of queueing for an hour
    {error, #{class := call}} = wasmtime:call(Inst, ~"nap", [], #{timeout => 5000}),
    ok = wasmtime:destroy(Inst).

precompiled(Config) ->
    {ok, Bin} = wasmtime:serialize(program(Config, "p3_cli_hello_stdout")),
    {ok, Mod} = wasmtime:deserialize(Bin),
    {ok, Inst} = wasmtime:instantiate(Mod, #{wasi => #{stdout => capture}}),
    ok = wasmtime:run(Inst),
    {ok, {~"hello, world\n", _, _}} = wasmtime:read_output(Inst),
    ok.
