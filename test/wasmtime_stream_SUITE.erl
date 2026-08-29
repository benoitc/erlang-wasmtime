%% Streams: the inbox, stdin/stdout streaming and the erlang imports.
-module(wasmtime_stream_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(wasmtime_test, [compile/1, channel_wat/0, channel_inst/0, channel_inst/1, collect/2]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    stream_channel_echo/1,
    stream_recv_small_buffer/1,
    stream_inbox_full/1,
    stream_close_then_send/1,
    stream_blocked_recv_interrupted/1,
    stream_blocked_recv_caller_dies/1,
    stream_reserved_import/1,
    stream_bad_import_type/1,
    stream_other_process/1,
    stream_dead_receiver/1,
    shim_files_load/1
]).

all() ->
    [{group, G} || {G, _, _} <- groups()].

groups() ->
    [
        {streams, [], [
            stream_channel_echo,
            stream_recv_small_buffer,
            stream_inbox_full,
            stream_close_then_send,
            stream_blocked_recv_interrupted,
            stream_blocked_recv_caller_dies,
            stream_reserved_import,
            stream_bad_import_type,
            stream_other_process,
            stream_dead_receiver,
            shim_files_load
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat], Config).

end_per_suite(_) -> ok.

stream_channel_echo(_) ->
    Inst = channel_inst(),
    {ok, R} = wasmtime:call_async(Inst, ~"echo", []),
    ok = wasmtime:send(Inst, ~"one"),
    ok = wasmtime:send(Inst, [~"tw", <<"o">>]),
    ok = wasmtime:send(Inst, <<>>),
    %% one message in, one message out: framing is kept
    [~"one", ~"two", <<>>] = collect(channel, 3),
    ok = wasmtime:close(Inst),
    {ok, [3]} = wasmtime:await(Inst, R),
    %% closed and drained: recv answers -1 at once
    {ok, [-1]} = wasmtime:call(Inst, ~"recv_into", [1024]),
    ok.

stream_recv_small_buffer(_) ->
    Inst = channel_inst(),
    ok = wasmtime:send(Inst, ~"hello world"),
    %% -2 - Needed, and the message stays queued
    {ok, [-13]} = wasmtime:call(Inst, ~"recv_into", [4]),
    {ok, [11]} = wasmtime:call(Inst, ~"recv_into", [11]),
    %% out of bounds pointers trap instead of touching memory
    {error, #{class := trap, message := Msg}} = wasmtime:call(Inst, ~"send_at", [65530, 100]),
    ?assertMatch({_, _}, binary:match(Msg, ~"out of bounds")),
    ok.

stream_inbox_full(_) ->
    Inst = channel_inst(#{inbox_limit => 16}),
    ok = wasmtime:send(Inst, ~"0123456789"),
    {error, #{kind := inbox_full}} = wasmtime:send(Inst, ~"0123456789"),
    ok = wasmtime:send(Inst, ~"123456"),
    {ok, R} = wasmtime:call_async(Inst, ~"echo", []),
    [~"0123456789", ~"123456"] = collect(channel, 2),
    %% room again once the guest has read
    ok = wasmtime:send(Inst, ~"0123456789"),
    [~"0123456789"] = collect(channel, 1),
    ok = wasmtime:close(Inst),
    {ok, [3]} = wasmtime:await(Inst, R),
    ok.

stream_close_then_send(_) ->
    Inst = channel_inst(),
    ok = wasmtime:send(Inst, ~"last"),
    ok = wasmtime:close(Inst),
    ok = wasmtime:close(Inst),
    {error, #{kind := closed}} = wasmtime:send(Inst, ~"late"),
    %% what was queued before close is still delivered
    {ok, [4]} = wasmtime:call(Inst, ~"recv_into", [1024]),
    {ok, [-1]} = wasmtime:call(Inst, ~"recv_into", [1024]),
    ok.

stream_blocked_recv_interrupted(_) ->
    Inst = channel_inst(),
    {error, #{kind := timeout}} = wasmtime:call(Inst, ~"echo", [], #{timeout => 100}),
    {ok, R} = wasmtime:call_async(Inst, ~"echo", []),
    timer:sleep(50),
    ok = wasmtime:interrupt(Inst),
    {error, #{kind := interrupt}} = wasmtime:await(Inst, R),
    %% the instance and its inbox are still usable
    ok = wasmtime:send(Inst, ~"still here"),
    {ok, [10]} = wasmtime:call(Inst, ~"recv_into", [1024]),
    ok.

stream_blocked_recv_caller_dies(_) ->
    Inst = channel_inst(#{stream => self()}),
    Pid = spawn(fun() -> wasmtime:call(Inst, ~"echo", []) end),
    timer:sleep(50),
    exit(Pid, kill),
    timer:sleep(50),
    %% the thread is free again
    ok = wasmtime:send(Inst, ~"x"),
    {ok, [1]} = wasmtime:call(Inst, ~"recv_into", [1024]),
    ok.

stream_reserved_import(_) ->
    Fun = fun(_, _) -> {ok, []} end,
    {error, #{class := link, kind := reserved_import}} =
        wasmtime:instantiate(compile(channel_wat()), #{imports => #{{~"erlang", ~"send"} => Fun}}),
    ok.

stream_bad_import_type(_) ->
    Wat =
        ~"""
    (module (import "erlang" "recv" (func (param i32) (result i64))))
    """,
    {error, #{class := link, kind := unsupported_type}} = wasmtime:instantiate(compile(Wat)),
    ok.

stream_other_process(_) ->
    Self = self(),
    Collector = spawn_link(fun() ->
        receive
            {wasmtime_stream, Ref, channel, B} -> Self ! {got, Ref, B}
        end
    end),
    Inst = channel_inst(#{stream => Collector}),
    ok = wasmtime:send(Inst, ~"routed"),
    ok = wasmtime:close(Inst),
    {ok, [1]} = wasmtime:call(Inst, ~"echo", []),
    receive
        {got, Ref, ~"routed"} when is_reference(Ref) -> ok
    after 2000 -> error(no_message)
    end,
    ok.

stream_dead_receiver(_) ->
    Dead = spawn(fun() -> ok end),
    timer:sleep(20),
    Inst = channel_inst(#{stream => Dead}),
    ok = wasmtime:send(Inst, ~"dropped"),
    ok = wasmtime:close(Inst),
    %% output to a gone process is discarded, the guest keeps going
    {ok, [1]} = wasmtime:call(Inst, ~"echo", []),
    ok.

shim_files_load(_) ->
    %% the committed shims for this platform (scripts/precompile-shims.sh)
    %% match the engines a runtime-only build creates: exact tunables per
    %% fuel variant, features a subset of any proposal set
    Priv = code:priv_dir(erlang_wasmtime),
    {ok, Platform} = file:read_file(filename:join(Priv, "wasmtime_platform")),
    Path = fun(V) ->
        filename:join([Priv, "shims", string:trim(binary_to_list(Platform)) ++ "-" ++ V ++ ".cwasm"])
    end,
    {ok, Plain} = file:read_file(Path("plain")),
    {ok, Fuel} = file:read_file(Path("fuel")),
    {ok, M1} = wasmtime:deserialize(Plain),
    [{~"memory", memory}, {~"fd_read", func}, {~"fd_fdstat_get", func}] = wasmtime:exports(M1),
    {ok, _} = wasmtime:deserialize(Plain, #{
        proposals => #{simd => false, threads => false, gc => false}
    }),
    {ok, _} = wasmtime:deserialize(Fuel, #{fuel => true}),
    {error, #{class := compile}} = wasmtime:deserialize(Plain, #{fuel => true}),
    ok.

%% ------------------------------------------------------------ references
