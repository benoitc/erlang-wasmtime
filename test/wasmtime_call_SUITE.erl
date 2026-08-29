%% Calling exports: values, traps and their traces, fuel, async calls,
%% globals and tables.
-module(wasmtime_call_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(wasmtime_test, [compile/1, instance/1, table_wat/0, async_inst/0, fuel_wat/0]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    func_no_params_no_results/1,
    func_i32_boundaries/1,
    func_i64_boundaries/1,
    func_f32_roundtrip/1,
    func_f64_roundtrip/1,
    func_negative_zero/1,
    func_nan_roundtrip/1,
    func_v128/1,
    func_multi_value/1,
    func_many_params/1,
    func_wrong_types/1,
    func_call_by_charlist_name/1,
    func_start_function/1,
    trap_indirect_call_to_null/1,
    trap_bad_signature/1,
    trap_table_out_of_bounds/1,
    trap_bad_conversion/1,
    trap_unreachable_message/1,
    trap_during_start/1,
    async_call_and_await/1,
    async_two_instances/1,
    async_await_timeout/1,
    async_host_served_in_await/1,
    fuel_bounds_a_call/1,
    fuel_needs_metered_module/1,
    fuel_precompiled/1,
    trap_trace/1,
    globals_get_set/1,
    tables_size_grow/1
]).

all() ->
    [{group, G} || {G, _, _} <- groups()].

groups() ->
    [
        {func, [parallel], [
            func_no_params_no_results,
            func_i32_boundaries,
            func_i64_boundaries,
            func_f32_roundtrip,
            func_f64_roundtrip,
            func_negative_zero,
            func_nan_roundtrip,
            func_v128,
            func_multi_value,
            func_many_params,
            func_wrong_types,
            func_call_by_charlist_name,
            func_start_function
        ]},
        {trap, [parallel], [
            trap_indirect_call_to_null,
            trap_bad_signature,
            trap_table_out_of_bounds,
            trap_bad_conversion,
            trap_unreachable_message,
            trap_during_start
        ]},
        {async, [parallel], [
            async_call_and_await,
            async_two_instances,
            async_await_timeout,
            async_host_served_in_await
        ]},
        {api, [parallel], [
            fuel_bounds_a_call,
            fuel_needs_metered_module,
            fuel_precompiled,
            trap_trace,
            globals_get_set,
            tables_size_grow
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat], Config).

end_per_suite(_) -> ok.

func_no_params_no_results(_) ->
    Inst = instance(~"(module (func (export \"nop\")))"),
    {ok, []} = wasmtime:call(Inst, ~"nop", []),
    ok.

func_i32_boundaries(_) ->
    Inst = instance(~"(module (func (export \"id\") (param i32) (result i32) local.get 0))"),
    {ok, [0]} = wasmtime:call(Inst, ~"id", [0]),
    {ok, [2147483647]} = wasmtime:call(Inst, ~"id", [2147483647]),
    {ok, [-2147483648]} = wasmtime:call(Inst, ~"id", [-2147483648]),
    %% unsigned input wraps to the signed result
    {ok, [-1]} = wasmtime:call(Inst, ~"id", [4294967295]),
    {ok, [-2147483648]} = wasmtime:call(Inst, ~"id", [2147483648]),
    {error, #{kind := badarg}} = wasmtime:call(Inst, ~"id", [4294967296]),
    {error, #{kind := badarg}} = wasmtime:call(Inst, ~"id", [-2147483649]),
    {error, #{kind := badarg}} = wasmtime:call(Inst, ~"id", [1.0]),
    ok.

func_i64_boundaries(_) ->
    Inst = instance(~"(module (func (export \"id\") (param i64) (result i64) local.get 0))"),
    Max = 9223372036854775807,
    Min = -9223372036854775808,
    {ok, [Max]} = wasmtime:call(Inst, ~"id", [Max]),
    {ok, [Min]} = wasmtime:call(Inst, ~"id", [Min]),
    {ok, [-1]} = wasmtime:call(Inst, ~"id", [18446744073709551615]),
    {error, #{kind := badarg}} = wasmtime:call(Inst, ~"id", [18446744073709551616]),
    ok.

func_f32_roundtrip(_) ->
    Inst = instance(~"(module (func (export \"id\") (param f32) (result f32) local.get 0))"),
    {ok, [1.5]} = wasmtime:call(Inst, ~"id", [1.5]),
    {ok, [-0.25]} = wasmtime:call(Inst, ~"id", [-0.25]),
    {ok, [3.0]} = wasmtime:call(Inst, ~"id", [3]),
    %% f32 precision: 0.1 does not survive
    {ok, [F]} = wasmtime:call(Inst, ~"id", [0.1]),
    ?assert(abs(F - 0.1) < 1.0e-7 andalso F =/= 0.1),
    {ok, [infinity]} = wasmtime:call(Inst, ~"id", [infinity]),
    {ok, [neg_infinity]} = wasmtime:call(Inst, ~"id", [neg_infinity]),
    %% beyond f32 range becomes infinity
    {ok, [infinity]} = wasmtime:call(Inst, ~"id", [1.0e300]),
    ok.

func_f64_roundtrip(_) ->
    Inst = instance(~"(module (func (export \"id\") (param f64) (result f64) local.get 0))"),
    {ok, [0.1]} = wasmtime:call(Inst, ~"id", [0.1]),
    {ok, [1.7976931348623157e308]} = wasmtime:call(Inst, ~"id", [1.7976931348623157e308]),
    {ok, [5.0e-324]} = wasmtime:call(Inst, ~"id", [5.0e-324]),
    {ok, [1.0e15]} = wasmtime:call(Inst, ~"id", [1000000000000000]),
    ok.

func_negative_zero(_) ->
    Inst = instance(
        ~"""
        (module
          (func (export "id") (param f64) (result f64) local.get 0)
          (func (export "sign") (param f64) (result i64) local.get 0 i64.reinterpret_f64))
        """
    ),
    {ok, [Z]} = wasmtime:call(Inst, ~"id", [-0.0]),
    ?assertEqual(<<-0.0/float>>, <<Z/float>>),
    {ok, [S]} = wasmtime:call(Inst, ~"sign", [-0.0]),
    ?assertEqual(-9223372036854775808, S),
    ok.

func_nan_roundtrip(_) ->
    Inst = instance(
        ~"""
        (module
          (func (export "nan") (result f64) f64.const nan)
          (func (export "nan32") (result f32) f32.const nan)
          (func (export "isnan") (param f64) (result i32)
            local.get 0 local.get 0 f64.ne)
          (func (export "inf") (result f64) f64.const inf)
          (func (export "neginf") (result f64) f64.const -inf))
        """
    ),
    {ok, [nan]} = wasmtime:call(Inst, ~"nan", []),
    {ok, [nan]} = wasmtime:call(Inst, ~"nan32", []),
    {ok, [1]} = wasmtime:call(Inst, ~"isnan", [nan]),
    {ok, [0]} = wasmtime:call(Inst, ~"isnan", [1.0]),
    {ok, [infinity]} = wasmtime:call(Inst, ~"inf", []),
    {ok, [neg_infinity]} = wasmtime:call(Inst, ~"neginf", []),
    ok.

func_v128(_) ->
    Inst = instance(
        ~"""
        (module
          (func (export "id") (param v128) (result v128) local.get 0)
          (func (export "add") (param v128 v128) (result v128)
            local.get 0 local.get 1 i32x4.add)
          (func (export "splat") (param i32) (result v128) local.get 0 i8x16.splat))
        """
    ),
    A = <<1:32/little, 2:32/little, 3:32/little, 4:32/little>>,
    B = <<10:32/little, 20:32/little, 30:32/little, 40:32/little>>,
    {ok, [A]} = wasmtime:call(Inst, ~"id", [A]),
    {ok, [<<11:32/little, 22:32/little, 33:32/little, 44:32/little>>]} =
        wasmtime:call(Inst, ~"add", [A, B]),
    {ok, [<<7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7>>]} =
        wasmtime:call(Inst, ~"splat", [7]),
    {error, #{kind := badarg}} = wasmtime:call(Inst, ~"id", [<<1, 2, 3>>]),
    {error, #{kind := badarg}} = wasmtime:call(Inst, ~"id", [42]),
    ok.

func_multi_value(_) ->
    Inst = instance(
        ~"""
        (module
          (func (export "mixed") (param i32 i64 f32 f64) (result f64 f32 i64 i32)
            local.get 3 local.get 2 local.get 1 local.get 0)
          (func (export "five") (result i32 i32 i32 i32 i32)
            i32.const 1 i32.const 2 i32.const 3 i32.const 4 i32.const 5))
        """
    ),
    {ok, [4.5, 3.5, 2, 1]} = wasmtime:call(Inst, ~"mixed", [1, 2, 3.5, 4.5]),
    {ok, [1, 2, 3, 4, 5]} = wasmtime:call(Inst, ~"five", []),
    ok.

func_many_params(_) ->
    N = 20,
    Params = lists:flatten(lists:duplicate(N, "i32 ")),
    Body = lists:flatten([io_lib:format("local.get ~p i32.add ", [I]) || I <- lists:seq(1, N - 1)]),
    Wat = io_lib:format(
        "(module (func (export \"sum\") (param ~s) (result i32) local.get 0 ~s))",
        [Params, Body]
    ),
    Inst = instance(Wat),
    Args = lists:seq(1, N),
    {ok, [210]} = wasmtime:call(Inst, ~"sum", Args),
    ok.

func_wrong_types(_) ->
    Inst = instance(~"(module (func (export \"f\") (param i32 f64) (result i32) local.get 0))"),
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"f", [1.0, 1.0]),
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"f", [1, <<>>]),
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"f", [1, nan_typo]),
    {error, #{class := call, kind := badarity}} = wasmtime:call(Inst, ~"f", []),
    {error, #{class := call, kind := badarity}} = wasmtime:call(Inst, ~"f", [1, 2.0, 3]),
    ?assertError(function_clause, wasmtime:call(Inst, ~"f", not_a_list)),
    ok.

func_call_by_charlist_name(_) ->
    Inst = instance(~"(module (func (export \"héllo\") (result i32) i32.const 7))"),
    {ok, [7]} = wasmtime:call(Inst, ~"héllo", []),
    {ok, [7]} = wasmtime:call(Inst, unicode:characters_to_binary("héllo"), []),
    {ok, [7]} = wasmtime:call(Inst, [~"hé", ~"llo"], []),
    ok.

func_start_function(_) ->
    %% a start function runs during instantiate and can call the host
    Self = self(),
    Wat =
        ~"""
        (module
          (import "env" "hello" (func $hello))
          (start $hello))
        """,
    {ok, _} = wasmtime:instantiate(compile(Wat), #{
        imports => #{
            {~"env", ~"hello"} => fun(_, []) ->
                Self ! started,
                {ok, []}
            end
        }
    }),
    receive
        started -> ok
    after 1000 -> ct:fail(start_not_run)
    end,
    ok.

%% ---------------------------------------------------------------- memory

trap_indirect_call_to_null(_) ->
    Inst = instance(table_wat()),
    {ok, [1]} = wasmtime:call(Inst, ~"call", [0]),
    {error, #{class := trap, kind := indirect_call_to_null}} = wasmtime:call(Inst, ~"call", [1]),
    ok.

trap_bad_signature(_) ->
    Inst = instance(table_wat()),
    {error, #{class := trap, kind := bad_signature}} = wasmtime:call(Inst, ~"call_f", [0]),
    ok.

trap_table_out_of_bounds(_) ->
    Inst = instance(table_wat()),
    {error, #{class := trap, kind := table_out_of_bounds}} = wasmtime:call(Inst, ~"call", [99]),
    ok.

trap_bad_conversion(_) ->
    Inst = instance(
        ~"""
        (module
          (func (export "trunc") (param f64) (result i32) local.get 0 i32.trunc_f64_s)
          (func (export "sat") (param f64) (result i32) local.get 0 i32.trunc_sat_f64_s))
        """
    ),
    {ok, [3]} = wasmtime:call(Inst, ~"trunc", [3.7]),
    {error, #{class := trap, kind := bad_conversion_to_integer}} = wasmtime:call(Inst, ~"trunc", [
        nan
    ]),
    {error, #{class := trap, kind := integer_overflow}} = wasmtime:call(Inst, ~"trunc", [1.0e20]),
    {ok, [2147483647]} = wasmtime:call(Inst, ~"sat", [1.0e20]),
    {ok, [0]} = wasmtime:call(Inst, ~"sat", [nan]),
    ok.

trap_unreachable_message(_) ->
    Inst = instance(~"(module (func (export \"f\") unreachable))"),
    {error, #{class := trap, kind := unreachable, message := Msg}} = wasmtime:call(Inst, ~"f", []),
    ?assertMatch({_, _}, binary:match(Msg, ~"wasm trap")),
    ?assertMatch({_, _}, binary:match(Msg, ~"backtrace")),
    ok.

trap_during_start(_) ->
    Mod = compile(~"(module (func $f unreachable) (start $f))"),
    {error, #{class := trap, kind := unreachable}} = wasmtime:instantiate(Mod),
    ok.

%% --------------------------------------------------------------- imports

async_call_and_await(_) ->
    Inst = async_inst(),
    {ok, R1} = wasmtime:call_async(Inst, ~"add", [1, 2]),
    {ok, R2} = wasmtime:call_async(Inst, ~"add", [10, 20]),
    %% queued in order, awaited in any order
    {ok, [30]} = wasmtime:await(Inst, R2),
    {ok, [3]} = wasmtime:await(Inst, R1),
    %% the reference is single-use: nothing is left for it
    {error, #{kind := timeout}} = wasmtime:await(Inst, R1, 50),
    ok.

async_two_instances(_) ->
    A = async_inst(),
    B = async_inst(),
    {ok, RA} = wasmtime:call_async(A, ~"add", [1, 1]),
    {ok, RB} = wasmtime:call_async(B, ~"add", [2, 2]),
    {ok, [4]} = wasmtime:await(B, RB),
    {ok, [2]} = wasmtime:await(A, RA),
    ok.

async_await_timeout(_) ->
    Inst = async_inst(),
    {ok, R} = wasmtime:call_async(Inst, ~"loop", []),
    {error, #{kind := timeout}} = wasmtime:await(Inst, R, 100),
    timer:sleep(50),
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2]),
    ok.

async_host_served_in_await(_) ->
    %% the host call waits for this process to reach await
    Inst = async_inst(),
    {ok, R} = wasmtime:call_async(Inst, ~"run", [21]),
    timer:sleep(50),
    receive
        {wasmtime_host_call, _, _, _, _} = M ->
            %% still in the mailbox: served below
            self() ! M
    after 0 -> ok
    end,
    {ok, [42]} = wasmtime:await(Inst, R),
    ok.

%% ------------------------------------------------------------ wasi stdio

fuel_bounds_a_call(_) ->
    {ok, Mod} = wasmtime:compile({wat, fuel_wat()}, #{fuel => true}),
    {ok, Inst} = wasmtime:instantiate(Mod),
    {ok, [1]} = wasmtime:call(Inst, ~"one", [], #{fuel => 1000}),
    {ok, Left} = wasmtime:fuel_remaining(Inst),
    ?assert(Left < 1000 andalso Left > 0),
    %% an endless loop stops when the fuel is gone, no timeout needed
    {error, #{class := trap, kind := out_of_fuel}} = wasmtime:call(Inst, ~"loop", [], #{
        fuel => 10000
    }),
    {ok, 0} = wasmtime:fuel_remaining(Inst),
    %% a bounded loop costs about one unit per instruction
    {ok, []} = wasmtime:call(Inst, ~"spin", [100], #{fuel => 100000}),
    {ok, Left2} = wasmtime:fuel_remaining(Inst),
    Used = 100000 - Left2,
    ?assert(Used > 100 andalso Used < 5000, Used),
    %% fuel belongs to the instance: a call without the option runs on what
    %% is left, and fuel => 0 means none at all
    {ok, [1]} = wasmtime:call(Inst, ~"one", []),
    {ok, Left3} = wasmtime:fuel_remaining(Inst),
    ?assert(Left3 < Left2),
    {error, #{kind := out_of_fuel}} = wasmtime:call(Inst, ~"one", [], #{fuel => 0}),
    ok.

fuel_needs_metered_module(_) ->
    Inst = instance(fuel_wat()),
    {error, #{class := call, kind := fuel_disabled}} = wasmtime:call(Inst, ~"one", [], #{fuel => 10}),
    {error, #{class := call, kind := fuel_disabled}} = wasmtime:fuel_remaining(Inst),
    {ok, [1]} = wasmtime:call(Inst, ~"one", []),
    ok.

fuel_precompiled(_) ->
    %% a metered module survives serialize/deserialize as a metered module
    {ok, Mod} = wasmtime:compile({wat, fuel_wat()}, #{fuel => true}),
    {ok, Bin} = wasmtime:serialize(Mod),
    {ok, Mod2} = wasmtime:deserialize(Bin),
    {ok, Inst} = wasmtime:instantiate(Mod2),
    {error, #{kind := out_of_fuel}} = wasmtime:call(Inst, ~"loop", [], #{fuel => 1000}),
    {ok, Plain} = wasmtime:compile({wat, fuel_wat()}),
    {ok, PBin} = wasmtime:serialize(Plain),
    {ok, Plain2} = wasmtime:deserialize(PBin),
    {ok, PInst} = wasmtime:instantiate(Plain2),
    {error, #{kind := fuel_disabled}} = wasmtime:call(PInst, ~"one", [], #{fuel => 10}),
    ok.

trap_trace(_) ->
    Inst = instance(
        ~"""
        (module
          (func $inner (export "inner") unreachable)
          (func $outer (export "outer") call $inner)
          (func (export "div") (param i32) (result i32) i32.const 1 local.get 0 i32.div_s))
        """
    ),
    {error, #{class := trap, kind := unreachable, trace := [Inner, Outer]}} =
        wasmtime:call(Inst, ~"outer", []),
    #{func_index := 0, func_name := ~"inner", func_offset := Off0} = Inner,
    #{func_index := 1, func_name := ~"outer", func_offset := Off1} = Outer,
    ?assert(is_integer(Off0) andalso is_integer(Off1)),
    {error, #{kind := integer_division_by_zero, trace := [#{func_index := 2}]}} =
        wasmtime:call(Inst, ~"div", [0]),
    %% errors without frames have no trace key
    {error, #{class := call} = E} = wasmtime:call(Inst, ~"nope", []),
    false = maps:is_key(trace, E),
    ok.

globals_get_set(_) ->
    Inst = instance(
        ~"""
        (module
          (global $c (export "c") i32 (i32.const 7))
          (global $m32 (export "m32") (mut i32) (i32.const 1))
          (global $m64 (export "m64") (mut i64) (i64.const 2))
          (global $f (export "f") (mut f64) (f64.const 1.5))
          (global $v (export "v") (mut v128) (v128.const i32x4 1 2 3 4))
          (func (export "bump") (global.set $m32 (i32.add (global.get $m32) (i32.const 1))))
          (func (export "get") (result i32) global.get $m32))
        """
    ),
    {ok, 7} = wasmtime:global_get(Inst, ~"c"),
    {error, #{class := global, kind := immutable}} = wasmtime:global_set(Inst, ~"c", 8),
    {ok, 1} = wasmtime:global_get(Inst, ~"m32"),
    ok = wasmtime:global_set(Inst, ~"m32", 41),
    {ok, []} = wasmtime:call(Inst, ~"bump", []),
    {ok, [42]} = wasmtime:call(Inst, ~"get", []),
    {ok, 42} = wasmtime:global_get(Inst, ~"m32"),
    ok = wasmtime:global_set(Inst, ~"m64", 1 bsl 40),
    {ok, 1099511627776} = wasmtime:global_get(Inst, ~"m64"),
    {ok, 1.5} = wasmtime:global_get(Inst, ~"f"),
    ok = wasmtime:global_set(Inst, ~"f", nan),
    {ok, nan} = wasmtime:global_get(Inst, ~"f"),
    {ok, <<1:32/little, 2:32/little, 3:32/little, 4:32/little>>} = wasmtime:global_get(Inst, ~"v"),
    ok = wasmtime:global_set(Inst, ~"v", <<0:128>>),
    {ok, <<0:128>>} = wasmtime:global_get(Inst, ~"v"),
    {error, #{class := global, kind := badarg}} = wasmtime:global_set(Inst, ~"m32", 1.5),
    {error, #{class := global, kind := badarg}} = wasmtime:global_set(Inst, ~"m32", 1 bsl 40),
    {error, #{class := global, kind := no_such_export}} = wasmtime:global_get(Inst, ~"nope"),
    {error, #{class := global, kind := no_such_export}} = wasmtime:global_get(Inst, ~"bump"),
    ok.

tables_size_grow(_) ->
    Inst = instance(
        ~"""
        (module
          (table (export "funcs") 2 4 funcref)
          (table (export "externs") 1 externref)
          (func (export "size") (result i32) table.size 0))
        """
    ),
    {ok, 2} = wasmtime:table_size(Inst, ~"funcs"),
    {ok, 2} = wasmtime:table_grow(Inst, ~"funcs", 1),
    {ok, 3} = wasmtime:table_size(Inst, ~"funcs"),
    {ok, [3]} = wasmtime:call(Inst, ~"size", []),
    %% past the declared maximum
    {error, #{class := table}} = wasmtime:table_grow(Inst, ~"funcs", 5),
    {ok, 1} = wasmtime:table_grow(Inst, ~"externs", 2),
    {ok, 3} = wasmtime:table_size(Inst, ~"externs"),
    {error, #{class := table, kind := no_such_export}} = wasmtime:table_size(Inst, ~"size"),
    ok.

%% --------------------------------------------------------- engine options
