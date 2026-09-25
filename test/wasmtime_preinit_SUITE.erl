%% Pre-initialization (preinit/3) and instance teardown (destroy/1).
-module(wasmtime_preinit_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([
    state_is_captured/1,
    start_section_runs_once/1,
    initialize_removed/1,
    remove_exports/1,
    init_fun/1,
    init_failures/1,
    host_functions_during_init/1,
    wasi_during_init/1,
    passive_data_kept/1,
    nan_bits_kept/1,
    multi_memory/1,
    sparse_memory_is_dense/1,
    serialize_and_pool/1,
    refused_modules/1,
    table_changed/1,
    destroy_idle/1,
    destroy_running/1,
    destroy_in_host_call/1,
    destroy_frees_pool_slot/1,
    destroy_twice/1,
    destroy_refs/1
]).

all() ->
    [{group, G} || {G, _, _} <- groups()].

groups() ->
    [
        {preinit, [parallel], [
            state_is_captured,
            start_section_runs_once,
            initialize_removed,
            remove_exports,
            init_fun,
            init_failures,
            host_functions_during_init,
            wasi_during_init,
            passive_data_kept,
            nan_bits_kept,
            multi_memory,
            sparse_memory_is_dense,
            serialize_and_pool,
            refused_modules,
            table_changed
        ]},
        {destroy, [], [
            destroy_idle,
            destroy_running,
            destroy_in_host_call,
            destroy_frees_pool_slot,
            destroy_twice,
            destroy_refs
        ]}
    ].

init_per_suite(Config) -> wasmtime_test:needs([compiler, wat, wasi], Config).

end_per_suite(_) -> ok.

wasm(Wat) ->
    {ok, Bin} = wasmtime:wat2wasm(Wat),
    Bin.

preinit(Wat, Opts, Init) -> wasmtime:preinit(wasm(Wat), Opts, Init).

run(Wasm) -> run(Wasm, #{}).
run(Wasm, Opts) ->
    {ok, Mod} = wasmtime:compile(Wasm),
    {ok, Inst} = wasmtime:instantiate(Mod, Opts),
    Inst.

counter_wat() ->
    ~"""
    (module
      (memory (export "memory") 1)
      (global $g (mut i32) (i32.const 0))
      (global $k i64 (i64.const 42))
      (global $f (mut f64) (f64.const 0))
      (data (i32.const 100) "hello")
      (func (export "_initialize")
        (i32.store (i32.const 200) (i32.const 7)))
      (func (export "init")
        (global.set $g (i32.const -5))
        (global.set $f (f64.const 2.5))
        (drop (memory.grow (i32.const 1)))
        (i32.store8 (i32.const 70000) (i32.const 9)))
      (func (export "bump") (result i32)
        (global.set $g (i32.add (global.get $g) (i32.const 1)))
        (global.get $g))
      (func (export "k") (result i64) (global.get $k))
      (func (export "f") (result f64) (global.get $f))
      (func (export "load") (param i32) (result i32)
        (i32.load8_u (local.get 0))))
    """.

state_is_captured(_) ->
    {ok, Out} = preinit(counter_wat(), #{}, [~"_initialize", ~"init"]),
    Inst = run(Out),
    {ok, [-4]} = wasmtime:call(Inst, ~"bump", []),
    {ok, [42]} = wasmtime:call(Inst, ~"k", []),
    {ok, [2.5]} = wasmtime:call(Inst, ~"f", []),
    {ok, [$h]} = wasmtime:call(Inst, ~"load", [100]),
    {ok, [7]} = wasmtime:call(Inst, ~"load", [200]),
    {ok, [9]} = wasmtime:call(Inst, ~"load", [70000]),
    {ok, {2, _}} = wasmtime:memory_size(Inst),
    %% each instance starts from the snapshot, not from the last one's state
    {ok, [-4]} = wasmtime:call(run(Out), ~"bump", []),
    ok.

start_section_runs_once(_) ->
    Wat =
        ~"""
    (module
      (global $g (mut i32) (i32.const 0))
      (func $start (global.set $g (i32.add (global.get $g) (i32.const 1))))
      (start $start)
      (func (export "g") (result i32) (global.get $g)))
    """,
    {ok, Out} = preinit(Wat, #{}, []),
    {ok, [1]} = wasmtime:call(run(Out), ~"g", []),
    ok.

initialize_removed(_) ->
    {ok, Out} = preinit(counter_wat(), #{}, [~"_initialize", ~"init"]),
    {ok, Mod} = wasmtime:compile(Out),
    Names = [N || {N, _} <- wasmtime:exports(Mod)],
    false = lists:member(~"_initialize", Names),
    true = lists:member(~"init", Names),
    false = lists:any(fun(N) -> binary:match(N, ~"__wasmtime_preinit") =/= nomatch end, Names),
    %% not called, so kept
    {ok, Out2} = preinit(counter_wat(), #{}, [~"init"]),
    {ok, Mod2} = wasmtime:compile(Out2),
    true = lists:member({~"_initialize", func}, wasmtime:exports(Mod2)),
    ok.

remove_exports(_) ->
    {ok, Out} = preinit(counter_wat(), #{remove_exports => [~"init", "k"]}, [~"init"]),
    {ok, Mod} = wasmtime:compile(Out),
    Names = [N || {N, _} <- wasmtime:exports(Mod)],
    [] = [N || N <- Names, N =:= ~"init" orelse N =:= ~"k"],
    ok.

init_fun(_) ->
    Self = self(),
    %% the fun runs in the caller: what it raises, preinit/3 raises
    ?assertError(
        {badmatch, _},
        preinit(counter_wat(), #{}, fun(I) -> {ok, []} = wasmtime:call(I, ~"k", []) end)
    ),
    Good = fun(Inst) ->
        {ok, []} = wasmtime:call(Inst, ~"init", []),
        {ok, [-4]} = wasmtime:call(Inst, ~"bump", []),
        Self ! ran,
        ok
    end,
    {ok, Out} = preinit(counter_wat(), #{}, Good),
    receive
        ran -> ok
    end,
    {ok, [-3]} = wasmtime:call(run(Out), ~"bump", []),
    %% anything but ok, {ok, _} or an error refuses the snapshot
    {error, #{class := preinit, kind := init}} = preinit(counter_wat(), #{}, fun(_) -> nope end),
    ok.

init_failures(_) ->
    Wat =
        ~"""
    (module
      (func (export "boom") unreachable)
      (func (export "ok")))
    """,
    {error, #{class := trap, kind := unreachable}} = preinit(Wat, #{}, [~"ok", ~"boom"]),
    {error, #{kind := no_such_export}} = preinit(Wat, #{}, [~"missing"]),
    ok.

host_functions_during_init(_) ->
    Wat =
        ~"""
    (module
      (import "env" "seed" (func $seed (result i32)))
      (global $g (mut i32) (i32.const 0))
      (func (export "init") (global.set $g (call $seed)))
      (func (export "g") (result i32) (global.get $g)))
    """,
    Imports = #{{~"env", ~"seed"} => fun(_, []) -> {ok, [1234]} end},
    {ok, Out} = preinit(Wat, #{imports => Imports}, [~"init"]),
    %% the result still imports env.seed: the instance must provide it
    {error, #{class := link}} = wasmtime:instantiate(element(2, wasmtime:compile(Out))),
    {ok, [1234]} = wasmtime:call(run(Out, #{imports => Imports}), ~"g", []),
    ok.

wasi_during_init(Config) ->
    Dir = filename:join(?config(priv_dir, Config), "preinit_wasi"),
    ok = filelib:ensure_path(Dir),
    ok = file:write_file(filename:join(Dir, "seed"), ~"xyz"),
    %% path_open "seed" under fd 3, read 3 bytes to address 64
    Wat =
        ~"""
    (module
      (import "wasi_snapshot_preview1" "path_open"
        (func $open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "fd_read"
        (func $read (param i32 i32 i32 i32) (result i32)))
      (memory (export "memory") 1)
      (data (i32.const 0) "seed")
      (func (export "init") (result i32)
        (drop (call $open (i32.const 3) (i32.const 0) (i32.const 0) (i32.const 4)
          (i32.const 0) (i64.const 2) (i64.const 0) (i32.const 0) (i32.const 16)))
        (i32.store (i32.const 32) (i32.const 64))
        (i32.store (i32.const 36) (i32.const 3))
        (call $read (i32.load (i32.const 16)) (i32.const 32) (i32.const 1) (i32.const 40)))
      (func (export "load") (param i32) (result i32) (i32.load8_u (local.get 0))))
    """,
    Wasi = #{wasi => #{dirs => [{"/", Dir, read}]}},
    {ok, Out} = preinit(Wat, Wasi, [~"init"]),
    Inst = run(Out, Wasi),
    {ok, [$x]} = wasmtime:call(Inst, ~"load", [64]),
    {ok, [$z]} = wasmtime:call(Inst, ~"load", [66]),
    ok.

passive_data_kept(_) ->
    Wat =
        ~"""
    (module
      (memory (export "memory") 1)
      (data $p "abc")
      (data (i32.const 10) "act")
      (func (export "init") (i32.store8 (i32.const 20) (i32.const 1)))
      (func (export "copy") (memory.init $p (i32.const 30) (i32.const 0) (i32.const 3)))
      (func (export "load") (param i32) (result i32) (i32.load8_u (local.get 0))))
    """,
    {ok, Out} = preinit(Wat, #{}, [~"init"]),
    Inst = run(Out),
    {ok, [$a]} = wasmtime:call(Inst, ~"load", [10]),
    {ok, [1]} = wasmtime:call(Inst, ~"load", [20]),
    {ok, []} = wasmtime:call(Inst, ~"copy", []),
    {ok, [$b]} = wasmtime:call(Inst, ~"load", [31]),
    ok.

nan_bits_kept(_) ->
    Wat =
        ~"""
    (module
      (global $f (mut f32) (f32.const 0))
      (global $v (mut v128) (v128.const i64x2 0 0))
      (func (export "init")
        (global.set $f (f32.reinterpret_i32 (i32.const 0x7fc01234)))
        (global.set $v (v128.const i64x2 -1 7)))
      (func (export "bits") (result i32) (i32.reinterpret_f32 (global.get $f)))
      (func (export "lane") (result i64) (i64x2.extract_lane 1 (global.get $v))))
    """,
    {ok, Out} = preinit(Wat, #{}, [~"init"]),
    Inst = run(Out),
    {ok, [16#7fc01234]} = wasmtime:call(Inst, ~"bits", []),
    {ok, [7]} = wasmtime:call(Inst, ~"lane", []),
    ok.

multi_memory(_) ->
    Wat =
        ~"""
    (module
      (memory $a (export "a") 1)
      (memory $b (export "b") 1)
      (func (export "init")
        (i32.store8 $a (i32.const 5) (i32.const 1))
        (i32.store8 $b (i32.const 6) (i32.const 2))))
    """,
    {ok, Out} = preinit(Wat, #{}, [~"init"]),
    Inst = run(Out),
    {ok, <<1>>} = wasmtime:read_memory(Inst, ~"a", 5, 1),
    {ok, <<2>>} = wasmtime:read_memory(Inst, ~"b", 6, 1),
    {ok, <<0>>} = wasmtime:read_memory(Inst, ~"b", 5, 1),
    ok.

%% Two bytes 20 MB apart: Wasmtime would copy them at every instantiation
%% rather than map an image, so the gap is filled (docs/preinit.md).
sparse_memory_is_dense(_) ->
    Wat =
        ~"""
    (module
      (memory (export "memory") 400)
      (func (export "init")
        (i32.store8 (i32.const 16) (i32.const 1))
        (i32.store8 (i32.const 20000000) (i32.const 2))))
    """,
    {ok, Out} = preinit(Wat, #{}, [~"init"]),
    ?assert(byte_size(Out) > 10_000_000),
    Inst = run(Out),
    {ok, <<1>>} = wasmtime:read_memory(Inst, 16, 1),
    {ok, <<2>>} = wasmtime:read_memory(Inst, 20000000, 1),
    %% under 16 MB of span, nothing is filled
    Small =
        ~"""
    (module
      (memory (export "memory") 100)
      (func (export "init")
        (i32.store8 (i32.const 16) (i32.const 1))
        (i32.store8 (i32.const 6000000) (i32.const 2))))
    """,
    {ok, Out2} = preinit(Small, #{}, [~"init"]),
    ?assert(byte_size(Out2) < 1000),
    ok.

serialize_and_pool(Config) ->
    {ok, Out} = preinit(counter_wat(), #{}, [~"_initialize", ~"init"]),
    Pool = wasmtime_test:pooling(),
    {ok, Mod} = wasmtime:compile(Out, Pool),
    {ok, Bin} = wasmtime:serialize(Mod),
    Path = filename:join(?config(priv_dir, Config), "counter.cwasm"),
    ok = file:write_file(Path, Bin),
    {ok, Loaded} = wasmtime:deserialize_file(Path, Pool),
    [
        begin
            {ok, I} = wasmtime:instantiate(Loaded),
            {ok, [-4]} = wasmtime:call(I, ~"bump", []),
            ok = wasmtime:destroy(I)
        end
     || _ <- lists:seq(1, 100)
    ],
    ok.

refused_modules(_) ->
    Refused = fun(Kind, Wat) ->
        {error, #{class := preinit, kind := Kind}} = preinit(Wat, #{}, [])
    end,
    Refused(unsupported_import, ~"(module (import \"env\" \"m\" (memory 1)))"),
    Refused(unsupported_import, ~"(module (import \"env\" \"g\" (global i32)))"),
    Refused(unsupported_import, ~"(module (import \"env\" \"t\" (table 1 funcref)))"),
    Refused(unsupported_type, ~"(module (global (mut externref) (ref.null extern)))"),
    Refused(unsupported_type, ~"(module (type (struct (field i32))))"),
    Refused(unsupported, ~"(module (memory 1 1 shared))"),
    {error, #{class := preinit, kind := malformed}} = wasmtime:preinit(~"garbage", #{}, []),
    {error, #{class := preinit, kind := malformed}} =
        wasmtime:preinit(<<0, "asm", 1, 0, 0, 0, 1, 100>>, #{}, []),
    {error, #{class := preinit, kind := unsupported}} =
        wasmtime:preinit(<<0, "asm", 13, 0, 1, 0>>, #{}, []),
    %% an immutable reference global and funcref tables are fine
    {ok, _} = preinit(
        ~"(module (global funcref (ref.null func)) (table 2 funcref) (func (export \"f\")))",
        #{},
        []
    ),
    ok.

table_changed(_) ->
    Wat =
        ~"""
    (module
      (table 2 funcref)
      (func $f)
      (elem declare func $f)
      (func (export "set") (table.set (i32.const 1) (ref.func $f)))
      (func (export "same") (table.set (i32.const 1) (ref.null func))))
    """,
    {error, #{class := preinit, kind := table_changed}} = preinit(Wat, #{}, [~"set"]),
    %% writing back what was there is no change
    {ok, _} = preinit(Wat, #{}, [~"same"]),
    ok.

%% ---------------------------------------------------------------- destroy

loop_wat() ->
    ~"""
    (module
      (import "h" "wait" (func $wait))
      (func (export "spin") (loop (br 0)))
      (func (export "host") (call $wait))
      (func (export "one") (result i32) (i32.const 1)))
    """.

loop_inst() ->
    wasmtime_test:instance(loop_wat(), #{
        imports => #{
            {~"h", ~"wait"} => fun(_, []) ->
                timer:sleep(infinity),
                {ok, []}
            end
        }
    }).

destroy_idle(_) ->
    Inst = loop_inst(),
    {ok, [1]} = wasmtime:call(Inst, ~"one", []),
    ok = wasmtime:destroy(Inst),
    {error, #{kind := stopped}} = wasmtime:call(Inst, ~"one", []),
    {error, #{kind := no_such_export}} = wasmtime:global_get(Inst, ~"g"),
    {error, #{kind := no_memory}} = wasmtime:read_memory(Inst, 0, 1),
    ok.

destroy_running(_) ->
    Inst = loop_inst(),
    Self = self(),
    spawn_link(fun() -> Self ! {spin, wasmtime:call(Inst, ~"spin", [])} end),
    timer:sleep(50),
    T0 = erlang:monotonic_time(millisecond),
    ok = wasmtime:destroy(Inst),
    ?assert(erlang:monotonic_time(millisecond) - T0 < 20),
    receive
        {spin, {error, #{kind := interrupt}}} -> ok
    end,
    ok.

destroy_in_host_call(_) ->
    Inst = loop_inst(),
    Self = self(),
    {ok, H} = wasmtime:call_async(Inst, ~"host", []),
    %% the host call arrives here; destroy from another process meanwhile
    receive
        {wasmtime_host_call, _, _, {~"h", ~"wait"}, []} -> ok
    end,
    spawn_link(fun() -> Self ! {destroyed, wasmtime:destroy(Inst)} end),
    receive
        {destroyed, ok} -> ok
    end,
    {error, #{kind := interrupt}} = wasmtime:await(Inst, H, 1000),
    ok.

destroy_frees_pool_slot(_) ->
    {ok, Mod} = wasmtime:compile({wat, ~"(module (memory 1))"}, wasmtime_test:pooling()),
    Held = [I || {ok, I} <- [wasmtime:instantiate(Mod) || _ <- lists:seq(1, 64)]],
    Full = wasmtime:instantiate(Mod),
    [ok = wasmtime:destroy(I) || I <- Held],
    %% every slot is free again at once, not at the next garbage collection
    Again = [wasmtime:instantiate(Mod) || _ <- Held],
    [ok = wasmtime:destroy(I) || {ok, I} <- Again],
    ?assertMatch({error, #{class := link}}, Full),
    ?assertEqual(length(Held), length([ok || {ok, _} <- Again])),
    ok.

destroy_twice(_) ->
    Inst = loop_inst(),
    ok = wasmtime:destroy(Inst),
    ok = wasmtime:destroy(Inst),
    ok.

destroy_refs(_) ->
    Inst = wasmtime_test:refs_inst(),
    {ok, R} = wasmtime:externref(Inst, kept),
    {ok, kept} = wasmtime:externref_data(R),
    ok = wasmtime:destroy(Inst),
    %% the store is gone: its refs answer instead of reaching it
    {error, #{kind := stopped}} = wasmtime:externref_data(R),
    {error, #{kind := stopped}} = wasmtime:ref_info(R),
    {error, #{kind := stopped}} = wasmtime:externref(Inst, again),
    {error, #{kind := stopped}} = wasmtime:gc(Inst),
    ok.
