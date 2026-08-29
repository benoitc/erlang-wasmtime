%% References across the boundary: funcref, externref and GC values.
-module(wasmtime_ref_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-import(wasmtime_test, [instance/1, refs_inst/0, refs_inst/1, gc_wat/0]).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    ref_externref_roundtrip/1,
    ref_externref_global/1,
    ref_null/1,
    ref_funcref_table/1,
    ref_funcref_nonnull/1,
    ref_wrong_instance/1,
    ref_host_functions/1,
    ref_i31/1,
    ref_struct/1,
    ref_array/1,
    ref_lifetime/1,
    ref_gc_stress/1
]).

all() ->
    [{group, G} || {G, _, _} <- groups()].

groups() ->
    [
        {references, [], [
            ref_externref_roundtrip,
            ref_externref_global,
            ref_null,
            ref_funcref_table,
            ref_funcref_nonnull,
            ref_wrong_instance,
            ref_host_functions,
            ref_i31,
            ref_struct,
            ref_array,
            ref_lifetime,
            ref_gc_stress
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat], Config).

end_per_suite(_) -> ok.

ref_externref_roundtrip(_) ->
    Inst = refs_inst(),
    {ok, Ref} = wasmtime:externref(Inst, #{a => 1}),
    #{kind := externref, instance := IRef} = wasmtime:ref_info(Ref),
    IRef = wasmtime:ref(Inst),
    {ok, [Back]} = wasmtime:call(Inst, ~"id_ext", [Ref]),
    {ok, #{a := 1}} = wasmtime:externref_data(Back),
    #{kind := externref} = wasmtime:ref_info(Back),
    %% a term of any shape, copied in and out
    {ok, Big} = wasmtime:externref(Inst, {self(), lists:seq(1, 1000), <<"bin">>}),
    {ok, {Pid, L, <<"bin">>}} = wasmtime:externref_data(Big),
    Pid = self(),
    1000 = length(L),
    ok.

ref_externref_global(_) ->
    Inst = refs_inst(),
    {ok, null} = wasmtime:global_get(Inst, ~"g"),
    {ok, Ref} = wasmtime:externref(Inst, hello),
    {ok, []} = wasmtime:call(Inst, ~"set_g", [Ref]),
    {ok, G} = wasmtime:global_get(Inst, ~"g"),
    {ok, hello} = wasmtime:externref_data(G),
    ok = wasmtime:global_set(Inst, ~"g", null),
    {ok, null} = wasmtime:global_get(Inst, ~"g"),
    {ok, Other} = wasmtime:externref(Inst, other),
    ok = wasmtime:global_set(Inst, ~"g", Other),
    {ok, G2} = wasmtime:global_get(Inst, ~"g"),
    {ok, other} = wasmtime:externref_data(G2),
    %% the externref table too
    ok = wasmtime:table_set(Inst, ~"e", 1, Other),
    {ok, E1} = wasmtime:table_get(Inst, ~"e", 1),
    {ok, other} = wasmtime:externref_data(E1),
    {ok, null} = wasmtime:table_get(Inst, ~"e", 2),
    {ok, 4} = wasmtime:table_grow(Inst, ~"e", 2, Other),
    {ok, E5} = wasmtime:table_get(Inst, ~"e", 5),
    {ok, other} = wasmtime:externref_data(E5),
    {error, #{class := table, kind := out_of_bounds}} = wasmtime:table_get(Inst, ~"e", 6),
    ok.

ref_null(_) ->
    Inst = refs_inst(),
    {ok, [null]} = wasmtime:call(Inst, ~"id_ext", [null]),
    {ok, [1]} = wasmtime:call(Inst, ~"is_null", [null]),
    {ok, Ref} = wasmtime:externref(Inst, x),
    {ok, [0]} = wasmtime:call(Inst, ~"is_null", [Ref]),
    %% a funcref where an externref is expected, and the reverse
    {ok, F} = wasmtime:table_get(Inst, ~"t", 0),
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"is_null", [F]),
    {error, #{class := table, kind := badarg}} = wasmtime:table_set(Inst, ~"t", 3, Ref),
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"is_null", [42]),
    ok.

ref_funcref_table(_) ->
    Inst = refs_inst(),
    {ok, Add} = wasmtime:table_get(Inst, ~"t", 0),
    #{kind := funcref} = wasmtime:ref_info(Add),
    {ok, [7]} = wasmtime:call_ref(Inst, Add, [3, 4]),
    {ok, Twice} = wasmtime:table_get(Inst, ~"t", 1),
    {ok, [6]} = wasmtime:call_ref(Inst, Twice, [3, 0]),
    {ok, null} = wasmtime:table_get(Inst, ~"t", 2),
    %% move a function to another slot, the guest sees it through call_indirect
    ok = wasmtime:table_set(Inst, ~"t", 2, Twice),
    {ok, [10]} = wasmtime:call(Inst, ~"call_slot", [2, 5, 0]),
    ok = wasmtime:table_set(Inst, ~"t", 2, null),
    {error, #{class := trap, kind := indirect_call_to_null}} =
        wasmtime:call(Inst, ~"call_slot", [2, 5, 0]),
    %% call_ref honours the usual checks and options
    {error, #{kind := badarity}} = wasmtime:call_ref(Inst, Add, [1]),
    {ok, [3]} = wasmtime:call_ref(Inst, Add, [1, 2], #{timeout => 1000}),
    {ok, R} = wasmtime:call_async(Inst, ~"add", [1, 1]),
    {ok, [2]} = wasmtime:await(Inst, R),
    ok.

ref_funcref_nonnull(_) ->
    Inst = refs_inst(),
    {ok, Add} = wasmtime:table_get(Inst, ~"t", 0),
    {ok, [1]} = wasmtime:call(Inst, ~"nonnull", [Add]),
    {error, #{class := call, kind := badarg}} = wasmtime:call(Inst, ~"nonnull", [null]),
    ok.

ref_wrong_instance(_) ->
    A = refs_inst(),
    B = refs_inst(),
    {ok, RefA} = wasmtime:externref(A, a),
    {error, #{class := call, kind := wrong_instance}} = wasmtime:call(B, ~"id_ext", [RefA]),
    {error, #{class := global, kind := wrong_instance}} = wasmtime:global_set(B, ~"g", RefA),
    {ok, FA} = wasmtime:table_get(A, ~"t", 0),
    {error, #{class := call, kind := wrong_instance}} = wasmtime:call_ref(B, FA, [1, 2]),
    {error, #{class := call, kind := badarg}} = wasmtime:call_ref(A, RefA, []),
    ok.

ref_host_functions(_) ->
    Self = self(),
    Inst = refs_inst(#{
        {~"env", ~"ext_id"} => fun(_, [X]) ->
            {ok, seen} = wasmtime:externref_data(X),
            Self ! {host_saw, wasmtime:ref_info(X)},
            {ok, [X]}
        end,
        {~"env", ~"take_fn"} => fun(Ctx, [F]) ->
            %% the guest is parked: calling it back is refused, but the
            %% funcref can be kept for later
            {error, #{kind := reentrant}} = wasmtime:call_ref(Ctx, F, [20, 22]),
            Self ! {fn, F},
            {ok, [1]}
        end
    }),
    {ok, Ref} = wasmtime:externref(Inst, seen),
    {ok, [Back]} = wasmtime:call(Inst, ~"via_host", [Ref]),
    {ok, seen} = wasmtime:externref_data(Back),
    receive
        {host_saw, #{kind := externref}} -> ok
    after 1000 -> error(no_host_call)
    end,
    {ok, [1]} = wasmtime:call(Inst, ~"host_fn", []),
    Fn =
        receive
            {fn, F0} -> F0
        after 1000 -> error(no_fn)
        end,
    {ok, [42]} = wasmtime:call_ref(Inst, Fn, [20, 22]),
    %% a host fun returning a value of the wrong type traps cleanly
    Bad = refs_inst(#{{~"env", ~"ext_id"} => fun(_, [_]) -> {ok, [42]} end}),
    {ok, R2} = wasmtime:externref(Bad, x),
    {error, #{class := host, message := Msg}} = wasmtime:call(Bad, ~"via_host", [R2]),
    ?assertMatch({_, _}, binary:match(Msg, ~"wrong type")),
    ok.

ref_i31(_) ->
    Inst = instance(gc_wat()),
    {ok, [{i31, 42}]} = wasmtime:call(Inst, ~"id_any", [{i31, 42}]),
    {ok, [{i31, -5}]} = wasmtime:call(Inst, ~"id_any", [{i31, -5}]),
    {ok, [-5]} = wasmtime:call(Inst, ~"i31v", [{i31, -5}]),
    {ok, [null]} = wasmtime:call(Inst, ~"id_any", [null]),
    {error, #{kind := badarg}} = wasmtime:call(Inst, ~"id_any", [{i31, 1 bsl 31}]),
    ok.

ref_struct(_) ->
    Inst = instance(gc_wat()),
    {ok, [P]} = wasmtime:call(Inst, ~"mk_point", [3, 2.5]),
    #{kind := struct} = wasmtime:ref_info(P),
    {ok, 3} = wasmtime:struct_get(P, 0),
    {ok, 2.5} = wasmtime:struct_get(P, 1),
    {ok, 7} = wasmtime:struct_get(P, 2),
    ok = wasmtime:struct_set(P, 0, 30),
    ok = wasmtime:struct_set(P, 2, 300),
    {ok, 44} = wasmtime:struct_get(P, 2),
    {ok, [30]} = wasmtime:call(Inst, ~"px", [P]),
    {error, #{class := ref, kind := out_of_bounds}} = wasmtime:struct_set(P, 9, 1),
    {error, #{class := ref}} = wasmtime:struct_get(P, 9),
    {error, #{class := ref, kind := badarg}} = wasmtime:struct_set(P, 0, 1.5),
    {error, #{class := ref, kind := badarg}} = wasmtime:array_len(P),
    %% the guest's own type check, through the typed call path
    {error, #{class := call}} = wasmtime:call(Inst, ~"want_arr", [P]),
    {ok, [P2]} = wasmtime:call(Inst, ~"id_any", [P]),
    {ok, 30} = wasmtime:struct_get(P2, 0),
    ok.

ref_array(_) ->
    Inst = instance(gc_wat()),
    {ok, [A]} = wasmtime:call(Inst, ~"mk_arr", [9]),
    #{kind := array} = wasmtime:ref_info(A),
    {ok, 5} = wasmtime:array_len(A),
    {ok, 9} = wasmtime:array_get(A, 4),
    ok = wasmtime:array_set(A, 0, 100),
    {ok, [100]} = wasmtime:call(Inst, ~"a0", [A]),
    {error, #{class := ref}} = wasmtime:array_get(A, 5),
    {error, #{class := ref}} = wasmtime:array_set(A, 5, 1),
    {error, #{class := ref, kind := badarg}} = wasmtime:struct_get(A, 0),
    {ok, [1]} = wasmtime:call(Inst, ~"want_arr", [A]),
    ok.

ref_lifetime(_) ->
    %% a ref outlives the handle it came from
    Ref = (fun() ->
        Inst = refs_inst(),
        {ok, R} = wasmtime:externref(Inst, kept),
        R
    end)(),
    erlang:garbage_collect(),
    timer:sleep(50),
    {ok, kept} = wasmtime:externref_data(Ref),
    #{kind := externref} = wasmtime:ref_info(Ref),
    %% the guest keeps an object the Erlang side dropped
    Inst = refs_inst(),
    ok = (fun() ->
        {ok, R} = wasmtime:externref(Inst, held),
        {ok, []} = wasmtime:call(Inst, ~"keep", [R]),
        ok
    end)(),
    erlang:garbage_collect(),
    ok = wasmtime:gc(Inst),
    {ok, Again} = wasmtime:table_get(Inst, ~"e", 0),
    {ok, held} = wasmtime:externref_data(Again),
    %% and once nobody does, gc/1 reclaims it (checked for leaks under ASan)
    ok = wasmtime:table_set(Inst, ~"e", 0, null),
    ok = wasmtime:gc(Inst),
    {ok, R} = wasmtime:call_async(Inst, ~"loop", []),
    timer:sleep(20),
    {error, #{kind := busy}} = wasmtime:gc(Inst),
    {error, #{kind := busy}} = wasmtime:externref_data(Again),
    ok = wasmtime:interrupt(Inst),
    {error, #{kind := interrupt}} = wasmtime:await(Inst, R),
    ok.

ref_gc_stress(_) ->
    Inst = refs_inst(),
    lists:foreach(
        fun(I) ->
            {ok, R} = wasmtime:externref(Inst, {I, lists:seq(1, 50)}),
            {ok, [R2]} = wasmtime:call(Inst, ~"id_ext", [R]),
            {ok, {I, _}} = wasmtime:externref_data(R2),
            I rem 1000 =:= 0 andalso wasmtime:gc(Inst)
        end,
        lists:seq(1, 20000)
    ),
    erlang:garbage_collect(),
    ok = wasmtime:gc(Inst),
    ok.
