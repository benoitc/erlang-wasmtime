%% Linear memory from Erlang, store limits and instance lifetime.
-module(wasmtime_memory_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(wasmtime_test, [compile/1, instance/1, instance/2]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    memory_data_segments/1,
    memory_grow_from_guest/1,
    memory_large_read_write/1,
    memory_first_export_used/1,
    memory_size_after_grow/1,
    memory_by_name/1,
    limits_unlimited_memory/1,
    limits_table_elements/1,
    limits_bad_option/1,
    limits_host_timeout_infinity/1,
    lifetime_instances_in_other_processes/1,
    lifetime_module_dropped_before_instance/1,
    lifetime_error_shape/1
]).

all() ->
    [{group, G} || {G, _, _} <- groups()].

groups() ->
    [
        {memory, [parallel], [
            memory_data_segments,
            memory_grow_from_guest,
            memory_large_read_write,
            memory_first_export_used,
            memory_size_after_grow
        ]},
        {memories, [parallel], [
            memory_by_name
        ]},
        {limits, [parallel], [
            limits_unlimited_memory,
            limits_table_elements,
            limits_bad_option,
            limits_host_timeout_infinity
        ]},
        {lifetime, [], [
            lifetime_instances_in_other_processes,
            lifetime_module_dropped_before_instance,
            lifetime_error_shape
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat], Config).

end_per_suite(_) -> ok.

memory_data_segments(_) ->
    Inst = instance(
        ~"""
        (module
          (memory (export "memory") 1)
          (data (i32.const 0) "hello")
          (data (i32.const 100) "\00\ff\7f"))
        """
    ),
    {ok, ~"hello"} = wasmtime:read_memory(Inst, 0, 5),
    {ok, <<0, 255, 127>>} = wasmtime:read_memory(Inst, 100, 3),
    {ok, <<0, 0, 0>>} = wasmtime:read_memory(Inst, 5, 3),
    ok.

memory_grow_from_guest(_) ->
    Inst = instance(
        ~"""
        (module
          (memory (export "memory") 1 4)
          (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
          (func (export "size") (result i32) memory.size))
        """
    ),
    {ok, [1]} = wasmtime:call(Inst, ~"size", []),
    {ok, [1]} = wasmtime:call(Inst, ~"grow", [2]),
    {ok, [3]} = wasmtime:call(Inst, ~"size", []),
    %% past the declared maximum
    {ok, [-1]} = wasmtime:call(Inst, ~"grow", [2]),
    {ok, [3]} = wasmtime:call(Inst, ~"grow", [1]),
    {ok, [-1]} = wasmtime:call(Inst, ~"grow", [1]),
    {ok, {4, 262144}} = wasmtime:memory_size(Inst),
    ok.

memory_large_read_write(_) ->
    Inst = instance(~"(module (memory (export \"memory\") 16))"),
    Data = crypto:strong_rand_bytes(1_000_000),
    ok = wasmtime:write_memory(Inst, 4096, Data),
    {ok, Data} = wasmtime:read_memory(Inst, 4096, 1_000_000),
    {ok, {16, 1048576}} = wasmtime:memory_size(Inst),
    ok = wasmtime:write_memory(Inst, 1048576 - 1, <<1>>),
    {error, #{kind := out_of_bounds}} = wasmtime:write_memory(Inst, 1048576 - 1, <<1, 2>>),
    {error, #{kind := out_of_bounds}} = wasmtime:read_memory(Inst, 1048576, 1),
    {error, #{kind := out_of_bounds}} = wasmtime:read_memory(Inst, 16#FFFFFFFFFFFFFFFF, 1),
    ok.

memory_first_export_used(_) ->
    %% no export named "memory": the first exported memory is used
    Inst = instance(
        ~"""
        (module
          (memory $a 1)
          (memory $b 2)
          (func (export "f"))
          (export "mem_b" (memory $b))
          (export "mem_a" (memory $a)))
        """
    ),
    {ok, {2, 131072}} = wasmtime:memory_size(Inst),
    ok.

memory_size_after_grow(_) ->
    Inst = instance(
        ~"""
        (module
          (memory (export "memory") 0)
          (func (export "grow") (param i32) (result i32) local.get 0 memory.grow))
        """
    ),
    {ok, {0, 0}} = wasmtime:memory_size(Inst),
    {error, #{kind := out_of_bounds}} = wasmtime:read_memory(Inst, 0, 1),
    {ok, <<>>} = wasmtime:read_memory(Inst, 0, 0),
    {ok, [0]} = wasmtime:call(Inst, ~"grow", [1]),
    {ok, {1, 65536}} = wasmtime:memory_size(Inst),
    ok = wasmtime:write_memory(Inst, 0, ~"now"),
    ok.

%% ------------------------------------------------------------------ trap

memory_by_name(_) ->
    Inst = instance(
        ~"""
        (module
          (memory $a 1)
          (memory $b 2)
          (export "memory" (memory $a))
          (export "scratch" (memory $b))
          (data (memory $b) (i32.const 0) "in b"))
        """
    ),
    {ok, {1, 65536}} = wasmtime:memory_size(Inst),
    {ok, {1, 65536}} = wasmtime:memory_size(Inst, ~"memory"),
    {ok, {2, 131072}} = wasmtime:memory_size(Inst, ~"scratch"),
    {ok, ~"in b"} = wasmtime:read_memory(Inst, ~"scratch", 0, 4),
    {ok, <<0, 0, 0, 0>>} = wasmtime:read_memory(Inst, 0, 4),
    ok = wasmtime:write_memory(Inst, ~"scratch", 100, ~"x"),
    ok = wasmtime:write_memory(Inst, "scratch", 101, ~"y"),
    {ok, ~"xy"} = wasmtime:read_memory(Inst, ~"scratch", 100, 2),
    {ok, <<0, 0>>} = wasmtime:read_memory(Inst, ~"memory", 100, 2),
    {error, #{class := memory, kind := no_memory}} = wasmtime:read_memory(Inst, ~"nope", 0, 1),
    {error, #{class := memory, kind := out_of_bounds}} =
        wasmtime:read_memory(Inst, ~"memory", 131000, 1),
    ok.

%% ---------------------------------------------------------- host process

limits_unlimited_memory(_) ->
    Wat =
        ~"""
        (module
          (memory (export "memory") 1)
          (func (export "grow") (param i32) (result i32) local.get 0 memory.grow))
        """,
    Small = instance(Wat, #{memory_limit => 65536}),
    {ok, [-1]} = wasmtime:call(Small, ~"grow", [1]),
    Big = instance(Wat, #{memory_limit => unlimited}),
    {ok, [1]} = wasmtime:call(Big, ~"grow", [100]),
    ok.

limits_table_elements(_) ->
    Wat =
        ~"""
        (module
          (table $t 1 funcref)
          (func (export "grow") (param i32) (result i32)
            ref.null func local.get 0 table.grow $t))
        """,
    Inst = instance(Wat, #{max_table_elements => 5}),
    {ok, [1]} = wasmtime:call(Inst, ~"grow", [4]),
    {ok, [-1]} = wasmtime:call(Inst, ~"grow", [1]),
    ok.

limits_bad_option(_) ->
    Mod = compile(~"(module)"),
    ?assertError({case_clause, 0}, wasmtime:instantiate(Mod, #{memory_limit => 0})),
    ?assertError({case_clause, -5}, wasmtime:instantiate(Mod, #{max_tables => -5})),
    ?assertError(function_clause, wasmtime:instantiate(Mod, [])),
    ok.

limits_host_timeout_infinity(_) ->
    Wat =
        ~"(module (import \"env\" \"f\" (func $f (result i32))) (func (export \"g\") (result i32) call $f))",
    Inst = instance(Wat, #{
        host_timeout => infinity,
        imports => #{
            {~"env", ~"f"} => fun(_, []) ->
                timer:sleep(100),
                {ok, [1]}
            end
        }
    }),
    {ok, [1]} = wasmtime:call(Inst, ~"g", []),
    ok.

%% -------------------------------------------------------------- lifetime

lifetime_instances_in_other_processes(_) ->
    %% an instance created in one process is callable from another
    Mod = compile(
        ~"""
        (module
          (memory (export "memory") 1)
          (func (export "store") (param i32) (i32.store (i32.const 0) (local.get 0)))
          (func (export "load") (result i32) (i32.load (i32.const 0))))
        """
    ),
    {ok, Inst} = wasmtime:instantiate(Mod),
    Self = self(),
    spawn_link(fun() -> Self ! {stored, wasmtime:call(Inst, ~"store", [77])} end),
    receive
        {stored, {ok, []}} -> ok
    after 1000 -> ct:fail(timeout)
    end,
    {ok, [77]} = wasmtime:call(Inst, ~"load", []),
    ok.

lifetime_module_dropped_before_instance(_) ->
    %% the instance keeps the compiled module alive
    Inst = instance(~"(module (func (export \"one\") (result i32) i32.const 1))"),
    erlang:garbage_collect(),
    {ok, [1]} = wasmtime:call(Inst, ~"one", []),
    ok.

lifetime_error_shape(_) ->
    %% every error carries the same three keys
    Errors = [
        wasmtime:compile(<<"x">>),
        wasmtime:instantiate(compile(~"(module (import \"a\" \"b\" (func)))")),
        wasmtime:call(instance(~"(module (func (export \"f\") unreachable))"), ~"f", []),
        wasmtime:call(instance(~"(module)"), ~"missing", []),
        wasmtime:read_memory(instance(~"(module)"), 0, 1)
    ],
    lists:foreach(
        fun({error, #{class := C, kind := K, message := M}}) ->
            true = is_atom(C) andalso is_atom(K) andalso is_binary(M)
        end,
        Errors
    ),
    5 = length(Errors),
    ok.

%% ----------------------------------------------------------- precompiled
