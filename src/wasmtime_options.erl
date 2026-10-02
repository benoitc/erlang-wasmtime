%% Compile options: the engine key the NIF reads, checked here because
%% Wasmtime aborts the process on an engine configuration it cannot build,
%% and back to options for module_options/1. docs/design.md, "Engines and
%% precompiled modules".
-module(wasmtime_options).
-moduledoc false.

-export([compile_key/1, key_to_options/1]).

-define(DEFAULT_MEMORY_LIMIT, 256 * 1024 * 1024).

%% The engine key the NIF reads: {Fuel, OptLevel, [{Proposal, Bool}],
%% Allocator} with the overrides sorted, so equal maps mean the same engine.
%% Malformed options raise; a set Wasmtime would refuse when the engine is
%% created (which it does by aborting the process) is returned as an error
%% here.
compile_key(Opts) when is_map(Opts) ->
    Fuel = maps:get(fuel, Opts, false),
    OptLevel = maps:get(opt_level, Opts, speed),
    Proposals = maps:get(proposals, Opts, #{}),
    true = is_boolean(Fuel),
    true = lists:member(OptLevel, [none, speed, speed_and_size]),
    maybe
        {ok, Overrides} ?= proposal_overrides(Proposals),
        {ok, Allocator} ?= allocator_key(Opts),
        {ok, {Fuel, OptLevel, Overrides, Allocator}}
    end.

%% Wasmtime builds the pool when the engine is created and aborts the
%% process if it cannot, so every bound it checks is checked here first.
%% A slot may not exceed the memory reservation (4 GB by default); the
%% instance cap keeps the reserved address space, about 4 GB per slot,
%% within what a 64-bit host maps. docs/design.md, "Numbers".
-define(POOL_MAX_INSTANCES, 10_000).
-define(POOL_MAX_SLOTS, 100_000).
-define(POOL_MAX_MEMORY, 4 bsl 30).
-define(WASM_PAGE, 16#10000).

allocator_key(Opts) ->
    case maps:get(allocator, Opts, on_demand) of
        on_demand ->
            {ok, on_demand};
        pooling ->
            Pool = maps:get(pooling, Opts, #{}),
            true = is_map(Pool),
            N = maps:get(instances, Pool, 1000),
            Max = maps:get(max_memory, Pool, ?DEFAULT_MEMORY_LIMIT),
            Keep = maps:get(keep_resident, Pool, 0),
            Slots = {
                maps:get(core_instances, Pool, N),
                maps:get(memories, Pool, N),
                maps:get(tables, Pool, N)
            },
            pooling_key(N, Max, Keep, Slots)
    end.

pooling_key(N, _, _, _) when not is_integer(N); N < 1; N > ?POOL_MAX_INSTANCES ->
    pool_error(~"pooling instances must be 1 to 10000");
pooling_key(_, Max, _, _) when
    not is_integer(Max); Max < ?WASM_PAGE; Max > ?POOL_MAX_MEMORY; Max rem ?WASM_PAGE =/= 0
->
    pool_error(~"pooling max_memory must be a multiple of 64 KB up to 4 GB");
pooling_key(_, Max, Keep, _) when not is_integer(Keep); Keep < 0; Keep > Max ->
    pool_error(~"pooling keep_resident must be 0 to max_memory");
pooling_key(_, _, _, {C, _, _}) when not is_integer(C); C < 1; C > ?POOL_MAX_SLOTS ->
    pool_error(~"pooling core_instances must be 1 to 100000");
pooling_key(_, _, _, {_, M, _}) when not is_integer(M); M < 1; M > ?POOL_MAX_INSTANCES ->
    pool_error(~"pooling memories must be 1 to 10000");
pooling_key(_, _, _, {_, _, T}) when not is_integer(T); T < 1; T > ?POOL_MAX_SLOTS ->
    pool_error(~"pooling tables must be 1 to 100000");
pooling_key(N, Max, Keep, {C, M, T}) ->
    {ok, {pooling, N, Max, Keep, C, M, T}}.

pool_error(Msg) -> {error, #{class => compile, kind => badarg, message => Msg}}.

%% Sorted, checked, with the implications Wasmtime insists on: relaxed SIMD
%% sits on SIMD, so turning SIMD off turns relaxed SIMD off too, and asking
%% for the opposite is refused.
proposal_overrides(Proposals) when is_map(Proposals) ->
    Overrides = lists:sort(maps:to_list(Proposals)),
    lists:foreach(
        fun({P, V}) ->
            true = is_proposal(P),
            true = is_boolean(V)
        end,
        Overrides
    ),
    case {maps:get(simd, Proposals, true), maps:get(relaxed_simd, Proposals, false)} of
        {false, true} ->
            {error, #{
                class => compile,
                kind => badarg,
                message => ~"relaxed_simd needs simd: disable both or neither"
            }};
        {false, false} ->
            {ok, lists:usort([{relaxed_simd, false} | Overrides])};
        {true, _} ->
            {ok, Overrides}
    end.

key_to_options({Fuel, OptLevel, Overrides, Allocator}) ->
    Base = #{fuel => Fuel, opt_level => OptLevel, proposals => maps:from_list(Overrides)},
    case Allocator of
        on_demand ->
            Base#{allocator => on_demand};
        {pooling, N, Max, Keep, C, M, T} ->
            Base#{
                allocator => pooling,
                pooling => #{
                    instances => N,
                    max_memory => Max,
                    keep_resident => Keep,
                    core_instances => C,
                    memories => M,
                    tables => T
                }
            }
    end.

is_proposal(P) ->
    lists:member(P, [
        simd,
        relaxed_simd,
        relaxed_simd_deterministic,
        bulk_memory,
        multi_value,
        multi_memory,
        memory64,
        tail_call,
        wide_arithmetic,
        custom_page_sizes,
        threads,
        reference_types,
        function_references,
        gc,
        exceptions
    ]).
