%% API coverage in the style of wasmtime-py's tests (test_module, test_func,
%% test_memory, test_trap, test_wasi, test_linker) and Wasmtime's own
%% examples, restricted to what this binding exposes.
-module(wasmtime_api_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2, end_per_group/2]).
-export([
    module_from_binary/1,
    module_from_wat/1,
    module_invalid/1,
    module_import_kinds/1,
    module_export_kinds/1,
    module_reuse_across_processes/1,
    module_validation_rejects_bad_types/1,
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
    memory_data_segments/1,
    memory_grow_from_guest/1,
    memory_large_read_write/1,
    memory_first_export_used/1,
    memory_size_after_grow/1,
    trap_indirect_call_to_null/1,
    trap_bad_signature/1,
    trap_table_out_of_bounds/1,
    trap_bad_conversion/1,
    trap_unreachable_message/1,
    trap_during_start/1,
    imports_several_functions/1,
    imports_same_name_different_module/1,
    imports_extra_keys_ignored/1,
    imports_non_function_refused/1,
    imports_host_calls_other_instance/1,
    imports_called_many_times/1,
    imports_host_reads_and_writes_memory/1,
    imports_no_result_host/1,
    imports_multi_result_host/1,
    wasi_args/1,
    wasi_env/1,
    wasi_stdin_file/1,
    wasi_stderr_file/1,
    wasi_write_dir/1,
    wasi_read_dir_refuses_write/1,
    wasi_no_wasi_no_imports/1,
    limits_unlimited_memory/1,
    limits_table_elements/1,
    limits_bad_option/1,
    limits_host_timeout_infinity/1,
    lifetime_instances_in_other_processes/1,
    lifetime_module_dropped_before_instance/1,
    lifetime_error_shape/1,
    serialize_roundtrip/1,
    serialize_rejects_garbage/1,
    memory_by_name/1,
    host_process_serves_calls/1,
    host_process_reentrancy_refused/1,
    host_process_gone/1
]).

all() ->
    [{group, G} || {G, _, _} <- groups()].

groups() ->
    [
        {module, [parallel], [
            module_from_binary,
            module_from_wat,
            module_invalid,
            module_import_kinds,
            module_export_kinds,
            module_reuse_across_processes,
            module_validation_rejects_bad_types
        ]},
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
        {memory, [parallel], [
            memory_data_segments,
            memory_grow_from_guest,
            memory_large_read_write,
            memory_first_export_used,
            memory_size_after_grow
        ]},
        {trap, [parallel], [
            trap_indirect_call_to_null,
            trap_bad_signature,
            trap_table_out_of_bounds,
            trap_bad_conversion,
            trap_unreachable_message,
            trap_during_start
        ]},
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
        {wasi, [], [
            wasi_args,
            wasi_env,
            wasi_stdin_file,
            wasi_stderr_file,
            wasi_write_dir,
            wasi_read_dir_refuses_write,
            wasi_no_wasi_no_imports
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
        ]},
        {precompiled, [parallel], [
            serialize_roundtrip,
            serialize_rejects_garbage
        ]},
        {memories, [parallel], [
            memory_by_name
        ]},
        {host_process, [parallel], [
            host_process_serves_calls,
            host_process_reentrancy_refused,
            host_process_gone
        ]}
    ].

init_per_suite(Config) ->
    case wasmtime:features() of
        #{compiler := true, wat := true} -> Config;
        _ -> {skip, "needs a build with a compiler and WAT"}
    end.

end_per_suite(_) -> ok.

init_per_group(wasi, Config) ->
    case wasmtime:features() of
        #{wasi := true} -> Config;
        _ -> {skip, "needs a build with WASI"}
    end;
init_per_group(_, Config) ->
    Config.

end_per_group(_, _) -> ok.

compile(Wat) ->
    {ok, Mod} = wasmtime:compile({wat, Wat}),
    Mod.

instance(Wat) -> instance(Wat, #{}).
instance(Wat, Opts) ->
    {ok, Inst} = wasmtime:instantiate(compile(Wat), Opts),
    Inst.

%% ---------------------------------------------------------------- module

module_from_binary(_) ->
    %% the smallest valid module: magic + version
    {ok, Mod} = wasmtime:compile(<<0, "asm", 1, 0, 0, 0>>),
    [] = wasmtime:imports(Mod),
    [] = wasmtime:exports(Mod),
    {ok, _} = wasmtime:instantiate(Mod),
    ok.

module_from_wat(_) ->
    {ok, _} = wasmtime:compile({wat, ~"(module)"}),
    {ok, _} = wasmtime:compile({wat, "(module)"}),
    {ok, _} = wasmtime:compile({wat, ["(mod", <<"ule)">>]}),
    {error, #{class := compile, message := Msg}} = wasmtime:compile({wat, ~"(modul)"}),
    ?assert(byte_size(Msg) > 0),
    ok.

module_invalid(_) ->
    {error, #{class := compile}} = wasmtime:compile(<<>>),
    {error, #{class := compile}} = wasmtime:compile(<<0, "asm", 2, 0, 0, 0>>),
    {error, #{class := compile}} = wasmtime:compile(<<0, "asm", 1, 0, 0, 0, 255>>),
    ?assertError(function_clause, wasmtime:compile(not_a_binary)),
    ok.

module_import_kinds(_) ->
    Mod = compile(
        ~"""
        (module
          (import "a" "f" (func))
          (import "a" "g" (global i32))
          (import "b" "t" (table 1 funcref))
          (import "b" "m" (memory 1))
          (import "c" "e" (tag)))
        """
    ),
    [
        {~"a", ~"f", func},
        {~"a", ~"g", global},
        {~"b", ~"t", table},
        {~"b", ~"m", memory},
        {~"c", ~"e", tag}
    ] = wasmtime:imports(Mod),
    ok.

module_export_kinds(_) ->
    Mod = compile(
        ~"""
        (module
          (func (export "f"))
          (global (export "g") i32 (i32.const 0))
          (table (export "t") 1 funcref)
          (memory (export "m") 1)
          (tag (export "e")))
        """
    ),
    [{~"f", func}, {~"g", global}, {~"t", table}, {~"m", memory}, {~"e", tag}] =
        wasmtime:exports(Mod),
    ok.

module_reuse_across_processes(_) ->
    Mod = compile(~"(module (func (export \"one\") (result i32) i32.const 1))"),
    Self = self(),
    Pids = [
        spawn_link(fun() ->
            {ok, Inst} = wasmtime:instantiate(Mod),
            Self ! {self(), wasmtime:call(Inst, ~"one", [])}
        end)
     || _ <- lists:seq(1, 10)
    ],
    [
        receive
            {P, R} -> {ok, [1]} = R
        after 5000 -> ct:fail(timeout)
        end
     || P <- Pids
    ],
    ok.

module_validation_rejects_bad_types(_) ->
    {error, #{class := compile, message := Msg}} =
        wasmtime:compile({wat, ~"(module (func (result i32) f32.const 1))"}),
    ?assertMatch({_, _}, binary:match(Msg, ~"type mismatch")),
    ok.

%% ------------------------------------------------------------------ func

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

table_wat() ->
    ~"""
    (module
      (type $i (func (result i32)))
      (type $f (func (result f64)))
      (table 4 funcref)
      (func $one (type $i) i32.const 1)
      (elem (i32.const 0) $one)
      (func (export "call") (param i32) (result i32)
        local.get 0 call_indirect (type $i))
      (func (export "call_f") (param i32) (result f64)
        local.get 0 call_indirect (type $f)))
    """.

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

%% Writes argv and environ, one entry per line, to stdout.
wasi_argv_wat() ->
    ~"""
    (module
      (import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes (param i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "args_get" (func $args_get (param i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "environ_sizes_get" (func $env_sizes (param i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "environ_get" (func $env_get (param i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "path_open"
        (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
      (memory (export "memory") 1)
      (data (i32.const 4000) "\n")
      (data (i32.const 4010) "new.txt")
      ;; write NUL-terminated string at $ptr to $fd, then a newline
      (func $puts (param $fd i32) (param $ptr i32) (local $len i32)
        (block (loop
          (br_if 1 (i32.eqz (i32.load8_u (i32.add (local.get $ptr) (local.get $len)))))
          (local.set $len (i32.add (local.get $len) (i32.const 1)))
          (br 0)))
        (i32.store (i32.const 0) (local.get $ptr))
        (i32.store (i32.const 4) (local.get $len))
        (drop (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8)))
        (i32.store (i32.const 0) (i32.const 4000))
        (i32.store (i32.const 4) (i32.const 1))
        (drop (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8))))
      ;; dump a (count, ptrs, buf) list obtained through $sizes/$get
      (func (export "args") (local $i i32) (local $n i32)
        (drop (call $args_sizes (i32.const 16) (i32.const 20)))
        (local.set $n (i32.load (i32.const 16)))
        (drop (call $args_get (i32.const 1000) (i32.const 2000)))
        (block (loop
          (br_if 1 (i32.ge_u (local.get $i) (local.get $n)))
          (call $puts (i32.const 1) (i32.load (i32.add (i32.const 1000) (i32.mul (local.get $i) (i32.const 4)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br 0))))
      (func (export "env") (local $i i32) (local $n i32)
        (drop (call $env_sizes (i32.const 16) (i32.const 20)))
        (local.set $n (i32.load (i32.const 16)))
        (drop (call $env_get (i32.const 1000) (i32.const 2000)))
        (block (loop
          (br_if 1 (i32.ge_u (local.get $i) (local.get $n)))
          (call $puts (i32.const 1) (i32.load (i32.add (i32.const 1000) (i32.mul (local.get $i) (i32.const 4)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br 0))))
      ;; copy up to 64 bytes of stdin to stderr, return bytes read
      (func (export "cat") (result i32)
        (i32.store (i32.const 0) (i32.const 3000))
        (i32.store (i32.const 4) (i32.const 64))
        (drop (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 8)))
        (i32.store (i32.const 4) (i32.load (i32.const 8)))
        (drop (call $fd_write (i32.const 2) (i32.const 0) (i32.const 1) (i32.const 12)))
        (i32.load (i32.const 8)))
      ;; create "new.txt" in preopen fd 3 with O_CREAT; returns errno
      (func (export "create") (result i32)
        (call $path_open (i32.const 3) (i32.const 0) (i32.const 4010) (i32.const 7)
                         (i32.const 1) (i64.const 0x40) (i64.const 0) (i32.const 0) (i32.const 64))))
    """.

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

serialize_roundtrip(_) ->
    Mod = compile(~"(module (func (export \"one\") (result i32) i32.const 1))"),
    {ok, Bin} = wasmtime:serialize(Mod),
    ?assert(byte_size(Bin) > 0),
    {ok, Mod2} = wasmtime:deserialize(Bin),
    [{~"one", func}] = wasmtime:exports(Mod2),
    {ok, Inst} = wasmtime:instantiate(Mod2),
    {ok, [1]} = wasmtime:call(Inst, ~"one", []),
    %% the precompiled form is not a wasm module and vice versa
    {error, #{class := compile}} = wasmtime:compile(Bin),
    ok.

serialize_rejects_garbage(_) ->
    {error, #{class := compile}} = wasmtime:deserialize(<<"not precompiled">>),
    {error, #{class := compile}} = wasmtime:deserialize(<<>>),
    {error, #{class := compile}} = wasmtime:deserialize(<<0, "asm", 1, 0, 0, 0>>),
    ok.

%% -------------------------------------------------------------- memories

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

host_wat() ->
    ~"""
    (module
      (import "env" "twice" (func $twice (param i32) (result i32)))
      (func (export "run") (param i32) (result i32) local.get 0 call $twice))
    """.

%% A handler process: serves host calls for Inst until told to stop.
handler(Parent) ->
    receive
        {inst, Inst} -> handler_loop(Parent, Inst)
    end.

handler_loop(Parent, Inst) ->
    receive
        stop ->
            ok;
        Msg ->
            case wasmtime:handle_host_call(Inst, Msg) of
                ok -> Parent ! {served, self()};
                ignore -> Parent ! {ignored, Msg}
            end,
            handler_loop(Parent, Inst)
    end.

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
