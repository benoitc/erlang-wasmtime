%% Modules: compiling, validating, inspecting, precompiling and the engine
%% options behind them.
-module(wasmtime_module_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(wasmtime_test, [compile/1, add_wat/0, add_binary/0, simd_binary/0, threads_binary/0]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    module_from_binary/1,
    module_from_wat/1,
    module_invalid/1,
    module_import_kinds/1,
    module_export_kinds/1,
    module_reuse_across_processes/1,
    module_validation_rejects_bad_types/1,
    serialize_roundtrip/1,
    serialize_rejects_garbage/1,
    opt_levels/1,
    opt_level_precompiled/1,
    proposals_restrict_validation/1,
    proposals_precompiled_loads_on_defaults/1,
    module_options_roundtrip/1,
    bad_compile_options/1,
    engine_cap/1,
    validate_module/1
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
        {precompiled, [parallel], [
            serialize_roundtrip,
            serialize_rejects_garbage
        ]},
        {engine_options, [], [
            opt_levels,
            opt_level_precompiled,
            proposals_restrict_validation,
            proposals_precompiled_loads_on_defaults,
            module_options_roundtrip,
            bad_compile_options,
            engine_cap
        ]},
        {validate, [parallel], [
            validate_module
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat], Config).

end_per_suite(_) -> ok.

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

opt_levels(_) ->
    lists:foreach(
        fun(Level) ->
            {ok, Mod} = wasmtime:compile({wat, add_wat()}, #{opt_level => Level}),
            #{opt_level := Level} = wasmtime:module_options(Mod),
            {ok, Inst} = wasmtime:instantiate(Mod),
            {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2])
        end,
        [none, speed, speed_and_size]
    ),
    ok.

opt_level_precompiled(_) ->
    %% the optimization level is not part of Wasmtime's compatibility check:
    %% a module compiled at `none` loads on any engine, and then belongs to
    %% the engine that loaded it
    {ok, Mod} = wasmtime:compile({wat, add_wat()}, #{opt_level => none}),
    {ok, Bin} = wasmtime:serialize(Mod),
    {ok, Mod2} = wasmtime:deserialize(Bin),
    #{opt_level := speed} = wasmtime:module_options(Mod2),
    {ok, Mod3} = wasmtime:deserialize(Bin, #{opt_level => speed_and_size}),
    #{opt_level := speed_and_size} = wasmtime:module_options(Mod3),
    {ok, Inst} = wasmtime:instantiate(Mod2),
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2]),
    %% fuel is checked: a metered module needs a metered engine
    {ok, Metered} = wasmtime:compile({wat, add_wat()}, #{fuel => true, opt_level => none}),
    {ok, MBin} = wasmtime:serialize(Metered),
    {error, #{class := compile}} = wasmtime:deserialize(MBin, #{opt_level => none}),
    {ok, _} = wasmtime:deserialize(MBin, #{fuel => true}),
    {ok, _} = wasmtime:deserialize(MBin),
    ok.

proposals_restrict_validation(_) ->
    %% validate/2 takes the binary form; these two are hand-assembled
    Simd = simd_binary(),
    ok = wasmtime:validate(Simd),
    {error, #{class := compile, message := Msg}} =
        wasmtime:validate(Simd, #{proposals => #{simd => false}}),
    ?assertMatch({_, _}, binary:match(Msg, ~"SIMD")),
    {error, #{class := compile}} = wasmtime:compile(Simd, #{proposals => #{simd => false}}),
    {ok, _} = wasmtime:compile(Simd, #{proposals => #{threads => false}}),
    Shared = threads_binary(),
    {ok, _} = wasmtime:compile(Shared),
    {error, #{class := compile}} = wasmtime:compile(Shared, #{proposals => #{threads => false}}),
    %% a set Wasmtime would refuse is an error here, never an engine abort
    {error, #{class := compile, kind := badarg}} =
        wasmtime:compile(Simd, #{proposals => #{simd => false, relaxed_simd => true}}),
    %% disabling SIMD implies disabling relaxed SIMD
    {ok, Mod} = wasmtime:compile(add_binary(), #{proposals => #{simd => false}}),
    #{proposals := #{simd := false, relaxed_simd := false}} = wasmtime:module_options(Mod),
    ok.

proposals_precompiled_loads_on_defaults(_) ->
    %% a module compiled with fewer proposals loads on the default engine:
    %% Wasmtime checks features as a subset
    {ok, Mod} = wasmtime:compile({wat, add_wat()}, #{
        proposals => #{simd => false, threads => false, gc => false}
    }),
    {ok, Bin} = wasmtime:serialize(Mod),
    {ok, Mod2} = wasmtime:deserialize(Bin),
    #{proposals := #{}} = wasmtime:module_options(Mod2),
    {ok, Inst} = wasmtime:instantiate(Mod2),
    {ok, [3]} = wasmtime:call(Inst, ~"add", [1, 2]),
    ok.

module_options_roundtrip(_) ->
    Opts = #{
        fuel => true,
        opt_level => speed_and_size,
        proposals => #{threads => false, memory64 => true}
    },
    {ok, Mod} = wasmtime:compile({wat, add_wat()}, Opts),
    Opts = wasmtime:module_options(Mod),
    {ok, Plain} = wasmtime:compile({wat, add_wat()}),
    #{fuel := false, opt_level := speed, proposals := #{}} = wasmtime:module_options(Plain),
    %% same options, same engine: a precompiled module from one loads with the other
    {ok, Bin} = wasmtime:serialize(Mod),
    {ok, Again} = wasmtime:deserialize(Bin, Opts),
    Opts = wasmtime:module_options(Again),
    ok.

bad_compile_options(_) ->
    ?assertError({badmatch, false}, wasmtime:compile({wat, add_wat()}, #{opt_level => fast})),
    ?assertError(
        {badmatch, false}, wasmtime:compile({wat, add_wat()}, #{proposals => #{nope => true}})
    ),
    ?assertError(
        {badmatch, false}, wasmtime:compile({wat, add_wat()}, #{proposals => #{simd => 'maybe'}})
    ),
    ?assertError({badmatch, false}, wasmtime:compile({wat, add_wat()}, #{fuel => 1})),
    ok.

engine_cap(_) ->
    %% distinct proposal sets each get an engine; the cap is 32 per VM
    Results = [
        wasmtime:compile({wat, add_wat()}, #{
            proposals => #{
                memory64 => N rem 2 =:= 0,
                multi_memory => N rem 4 < 2,
                wide_arithmetic => N rem 8 < 4,
                custom_page_sizes => N rem 16 < 8,
                tail_call => N rem 32 < 16,
                relaxed_simd => N < 32
            }
        })
     || N <- lists:seq(0, 63)
    ],
    Ok = length([ok || {ok, _} <- Results]),
    Refused = length([r || {error, #{kind := too_many_configurations}} <- Results]),
    ?assert(Ok >= 1),
    ?assert(Refused >= 1),
    64 = Ok + Refused,
    %% existing engines keep working
    {ok, _} = wasmtime:compile({wat, add_wat()}),
    ok.

validate_module(_) ->
    ok = wasmtime:validate(<<0, "asm", 1, 0, 0, 0>>),
    {error, #{class := compile}} = wasmtime:validate(<<"garbage">>),
    %% a type section announcing five entries and holding none
    {error, #{class := compile, message := Msg}} = wasmtime:validate(
        <<0, "asm", 1, 0, 0, 0, 1, 1, 5>>
    ),
    ?assert(byte_size(Msg) > 0),
    ok.
