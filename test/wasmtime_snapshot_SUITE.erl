%% snapshot/1,2 and restore/3: an image of a live instance, with
%% erlang_wasm's functions. The image is a pre-initialized module, so what
%% preinit/3 refuses is refused here too (wasmtime_preinit_SUITE).
-module(wasmtime_snapshot_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    restore_starts_where_the_capture_was/1,
    start_section_runs_once/1,
    imports_are_given_again/1,
    capture_needs_snapshotable/1,
    capture_needs_a_loaded_module/1,
    capture_refuses_a_running_instance/1,
    capture_refuses_a_changed_table/1,
    capture_refuses_what_preinit_refuses/1,
    compatibility_key/1,
    snapshot_info_and_holders/1,
    save_and_load/1,
    load_refuses/1,
    worker_restores_per_request/1
]).

all() ->
    [
        restore_starts_where_the_capture_was,
        start_section_runs_once,
        imports_are_given_again,
        capture_needs_snapshotable,
        capture_needs_a_loaded_module,
        capture_refuses_a_running_instance,
        capture_refuses_a_changed_table,
        capture_refuses_what_preinit_refuses,
        compatibility_key,
        snapshot_info_and_holders,
        save_and_load,
        load_refuses,
        worker_restores_per_request
    ].

init_per_suite(Config) ->
    case wasmtime_test:needs([compiler, wat], Config) of
        {skip, _} = Skip ->
            Skip;
        _ ->
            {ok, _} = application:ensure_all_started(erlang_wasmtime),
            Config
    end.

end_per_suite(_) -> ok.

wat() ->
    ~"""
    (module
      (import "env" "seed" (func $seed (result i32)))
      (memory (export "memory") 1)
      (table (export "t") 2 funcref)
      (global $n (mut i32) (i32.const 0))
      (global $started (mut i32) (i32.const 0))
      (func $start (global.set $started (i32.add (global.get $started) (i32.const 1))))
      (start $start)
      (func (export "init")
        (global.set $n (call $seed))
        (i32.store (i32.const 1024) (i32.const 77)))
      (func (export "n") (result i32) global.get $n)
      (func (export "started") (result i32) global.get $started)
      (func (export "peek") (result i32) (i32.load (i32.const 1024)))
      (func (export "bump") (result i32)
        (global.set $n (i32.add (global.get $n) (i32.const 1))) global.get $n)
      (func (export "spin") (loop br 0))
      (func $f)
      (func (export "set_table") (table.set (i32.const 0) (ref.func $f)))
      (elem declare func $f))
    """.

imports(Seed) -> #{{~"env", ~"seed"} => fun(_Ctx, []) -> {ok, [Seed]} end}.

loaded() ->
    {ok, Mod} = wasmtime:load({wat, wat()}),
    Mod.

init_instance() ->
    {ok, Init} = wasmtime:instantiate(loaded(), imports(40), #{snapshotable => true}),
    {ok, []} = wasmtime:call(Init, ~"init", []),
    Init.

restore_starts_where_the_capture_was(_) ->
    Init = init_instance(),
    {ok, Image} = wasmtime:snapshot(Init),
    %% the capture leaves the instance as it was
    {ok, [41]} = wasmtime:call(Init, ~"bump", []),
    ok = wasmtime:destroy(Init),
    {ok, A} = wasmtime:restore(Image, imports(0), #{}),
    {ok, B} = wasmtime:restore(Image, imports(0), #{}),
    {ok, [40]} = wasmtime:call(A, ~"n", []),
    {ok, [77]} = wasmtime:call(A, ~"peek", []),
    %% each restored instance is its own
    {ok, [41]} = wasmtime:call(A, ~"bump", []),
    {ok, [40]} = wasmtime:call(B, ~"n", []),
    %% the instrumented exports are not shown
    false = lists:any(
        fun(N) -> binary:match(N, ~"__wasmtime") =/= nomatch end,
        maps:keys(wasmtime:exports(Init))
    ),
    ok.

start_section_runs_once(_) ->
    Init = init_instance(),
    {ok, [1]} = wasmtime:call(Init, ~"started", []),
    {ok, Image} = wasmtime:snapshot(Init),
    {ok, Fresh} = wasmtime:restore(Image, imports(0), #{}),
    {ok, [1]} = wasmtime:call(Fresh, ~"started", []),
    ok.

imports_are_given_again(_) ->
    {ok, Image} = wasmtime:snapshot(init_instance()),
    {error, #{class := link}} = wasmtime:restore(Image, #{}, #{}),
    {ok, Fresh} = wasmtime:restore(Image, imports(5), #{timeout => 50}),
    {ok, []} = wasmtime:call(Fresh, ~"init", []),
    {ok, [5]} = wasmtime:call(Fresh, ~"n", []),
    %% instantiate options apply to a restored instance
    {error, #{kind := timeout}} = wasmtime:call(Fresh, ~"spin", []),
    ok.

capture_needs_snapshotable(_) ->
    {ok, Plain} = wasmtime:instantiate(loaded(), imports(1), #{}),
    {error, #{class := invalid, kind := not_snapshotable}} = wasmtime:snapshot(Plain),
    {ok, Image} = wasmtime:snapshot(init_instance()),
    {error, #{class := invalid, kind := not_snapshotable}} =
        wasmtime:restore(Image, imports(1), #{snapshotable => true}),
    ok.

capture_needs_a_loaded_module(_) ->
    {ok, Compiled} = wasmtime:compile({wat, wat()}),
    {error, #{class := invalid, kind := module_not_loaded}} =
        wasmtime:instantiate(Compiled, imports(1), #{snapshotable => true}),
    ok.

capture_refuses_a_running_instance(_) ->
    Init = init_instance(),
    {ok, Ref} = wasmtime:call_async(Init, ~"spin", []),
    timer:sleep(50),
    {error, #{class := link, kind := busy}} = wasmtime:snapshot(Init),
    ok = wasmtime:interrupt(Init),
    {error, _} = wasmtime:await(Init, Ref),
    {ok, _} = wasmtime:snapshot(Init),
    ok = wasmtime:destroy(Init),
    %% a destroyed instance has nothing left to read
    {error, #{}} = wasmtime:snapshot(Init),
    ok.

capture_refuses_a_changed_table(_) ->
    Init = init_instance(),
    {ok, []} = wasmtime:call(Init, ~"set_table", []),
    {error, #{class := link, kind := table_changed}} = wasmtime:snapshot(Init),
    ok.

capture_refuses_what_preinit_refuses(_) ->
    {ok, Imported} = wasmtime:load({wat, ~"(module (import \"env\" \"m\" (memory 1)))"}),
    {error, #{class := link, kind := unsupported_import}} =
        wasmtime:instantiate(Imported, #{}, #{snapshotable => true}),
    ok.

compatibility_key(_) ->
    Init = init_instance(),
    {ok, Keyed} = wasmtime:snapshot(Init, #{version => ~"2", compatibility_key => {abi, 1}}),
    {ok, _} = wasmtime:restore(Keyed, imports(0), #{compatibility_key => {abi, 1}}),
    {error, #{class := invalid, kind := snapshot_incompatible}} =
        wasmtime:restore(Keyed, imports(0), #{compatibility_key => {abi, 2}}),
    {error, #{class := invalid, kind := snapshot_incompatible}} =
        wasmtime:restore(Keyed, imports(0), #{}),
    {ok, Plain} = wasmtime:snapshot(Init),
    {error, #{class := invalid, kind := snapshot_incompatible}} =
        wasmtime:restore(Plain, imports(0), #{compatibility_key => {abi, 1}}),
    ok.

snapshot_info_and_holders(_) ->
    {ok, Image} = wasmtime:snapshot(init_instance(), #{version => ~"7"}),
    #{bytes := Bytes, module := Mod, version := ~"7"} = wasmtime:snapshot_info(Image),
    true = Bytes > 0,
    module = wasmtime:module_kind(Mod),
    ok = wasmtime:acquire(Image),
    ok = wasmtime:release(Image),
    %% the image outlives the process that took it and the module's unload
    Self = self(),
    {Pid, Mon} = spawn_monitor(fun() ->
        {ok, I} = wasmtime:snapshot(init_instance()),
        Self ! {image, I}
    end),
    Other =
        receive
            {image, I} -> I
        end,
    receive
        {'DOWN', Mon, process, Pid, _} -> ok
    end,
    {ok, Fresh} = wasmtime:restore(Other, imports(0), #{}),
    {ok, [40]} = wasmtime:call(Fresh, ~"n", []),
    ok.

save_and_load(Config) ->
    Path = filename:join(proplists:get_value(priv_dir, Config), "image.snap"),
    {ok, Image} = wasmtime:snapshot(init_instance(), #{version => ~"3", compatibility_key => k}),
    ok = wasmtime:save_snapshot(Image, Path),
    ok = wasmtime:save_snapshot(Image, Path),
    [_] = filelib:wildcard(Path ++ "*"),
    {ok, Loaded} = wasmtime:load_snapshot(Path, loaded()),
    #{version := ~"3"} = wasmtime:snapshot_info(Loaded),
    {error, #{kind := snapshot_incompatible}} = wasmtime:restore(Loaded, imports(0), #{}),
    {ok, Fresh} = wasmtime:restore(Loaded, imports(0), #{compatibility_key => k}),
    {ok, [40]} = wasmtime:call(Fresh, ~"n", []),
    {ok, [77]} = wasmtime:call(Fresh, ~"peek", []),
    {error, #{class := link, kind := snapshot_not_written}} =
        wasmtime:save_snapshot(Image, filename:join([Path, "no", "such", "dir"])),
    ok.

load_refuses(Config) ->
    Dir = proplists:get_value(priv_dir, Config),
    Path = filename:join(Dir, "refused.snap"),
    {ok, Image} = wasmtime:snapshot(init_instance()),
    ok = wasmtime:save_snapshot(Image, Path),
    {ok, Other} = wasmtime:load({wat, ~"(module (memory 1))"}),
    {error, #{class := invalid, kind := snapshot_incompatible}} = wasmtime:load_snapshot(
        Path, Other
    ),
    {ok, Compiled} = wasmtime:compile({wat, wat()}),
    {error, #{class := invalid, kind := module_not_loaded}} = wasmtime:load_snapshot(
        Path, Compiled
    ),
    {error, #{class := link, kind := snapshot_not_read}} =
        wasmtime:load_snapshot(filename:join(Dir, "missing.snap"), loaded()),
    Junk = filename:join(Dir, "junk.snap"),
    ok = file:write_file(Junk, ~"not an image"),
    {error, #{class := malformed, kind := snapshot_not_read}} = wasmtime:load_snapshot(
        Junk, loaded()
    ),
    ok = file:write_file(Junk, term_to_binary({wasmtime_snapshot, 1, not_a_hash, 1, 1, 1})),
    {error, #{class := malformed, kind := snapshot_not_read}} = wasmtime:load_snapshot(
        Junk, loaded()
    ),
    ok.

%% The use it is for: initialize once, give every request a restored instance.
worker_restores_per_request(_) ->
    {ok, Image} = wasmtime:snapshot(init_instance()),
    #{module := Mod} = wasmtime:snapshot_info(Image),
    {ok, W} = wasmtime_instance_worker:start_link(Mod, #{imports => imports(0)}),
    {ok, [41]} = wasmtime_instance_worker:call(W, ~"bump", []),
    {ok, [41]} = wasmtime_instance_worker:call(W, ~"bump", []),
    ok = wasmtime_instance_worker:stop(W).
