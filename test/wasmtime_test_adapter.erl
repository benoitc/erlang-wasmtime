%% An adapter for the script worker's own tests: a small WASI module and a
%% request that says which export to call, so the kernel is tested without
%% an interpreter. Request keys:
%%   call => {Name, Args}   the export to call (default {~"echo", [1]})
%%   then => {Name, Args}   a second call
%%   files => [{Path, Bytes}]  staged into the `ro` mount
%%   needs => map()         merged over the requirements
%%   mount => read | write  the `ro` mount's mode
%%   notify => pid()        told `{prepared, Dir}` and `{cleaned, Dir}`
%%   raise => prepare | decode | cleanup   a callback that crashes
-module(wasmtime_test_adapter).
-behaviour(wasmtime_worker_adapter).

-export([
    artifact/1,
    requirements/2,
    prepare/3,
    decode/2,
    cleanup/1,
    capabilities/1,
    conformance_fixtures/1,
    classify/2
]).

wat() ->
    ~"""
    (module
      (import "wasi_snapshot_preview1" "fd_write"
        (func $write (param i32 i32 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
      (memory (export "memory") 1 64)
      (global $n (mut i32) (i32.const 0))
      (data (i32.const 64) "0123456789abcdef")
      (func (export "echo") (param i32) (result i32) (i32.add (local.get 0) (i32.const 1)))
      (func (export "bump") (result i32)
        (global.set $n (i32.add (global.get $n) (i32.const 1))) global.get $n)
      (func (export "spin") (loop br 0))
      (func (export "boom") unreachable)
      (func (export "exit") (param i32) (call $exit (local.get 0)))
      (func (export "grow") (param i32) (result i32) local.get 0 memory.grow)
      ;; writes 16 bytes to stdout, N times
      (func (export "print") (param $times i32)
        (i32.store (i32.const 0) (i32.const 64))
        (i32.store (i32.const 4) (i32.const 16))
        (block $done
          (loop $again
            (br_if $done (i32.eqz (local.get $times)))
            (drop (call $write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 32)))
            (local.set $times (i32.sub (local.get $times) (i32.const 1)))
            (br $again)))))
    """.

artifact(#{fail := true}) ->
    {error, wasmtime_worker_error:adapter(adapter_failure, ~"told to fail", #{})};
artifact(_Opts) ->
    {ok, Module} = wasmtime:compile({wat, wat()}),
    {ok, #{module => Module}}.

requirements(#{raise := requirements}, _Artifact) ->
    error(requirements_crashed);
requirements(Request, _Artifact) when is_map(Request) ->
    Files = maps:get(files, Request, []),
    Base = #{
        min_timeout => 1,
        min_memory_pages => 1,
        request_bytes => 0,
        staged_bytes => lists:sum([iolist_size(B) || {_, B} <- Files]),
        staged_files => length(Files),
        mounts => #{ro => #{guest_path => ~"/", mode => maps:get(mount, Request, read)}}
    },
    {ok, maps:merge(Base, maps:get(needs, Request, #{}))};
requirements(_Request, _Artifact) ->
    {error, wasmtime_worker_error:adapter(adapter_failure, ~"request is not a map", #{})}.

prepare(#{raise := prepare}, _Artifact, _Env) ->
    error(prepare_crashed);
prepare(Request, #{module := Module}, #{stage := Stage, mounts := #{ro := #{host_dir := Dir}}}) ->
    State = Request#{dir => Dir},
    notify(State, prepared),
    case stage_all(Stage, maps:get(files, Request, [])) of
        ok ->
            Calls =
                [maps:get(call, Request, {~"echo", [1]})] ++
                    [C || {then, C} <- maps:to_list(Request)],
            {ok,
                #{
                    mode => reactor,
                    module => Module,
                    imports => #{bindings => #{}},
                    options => #{wasi => #{dirs => [{~"/", Dir, maps:get(mount, Request, read)}]}},
                    invoke => [{call, Name, Args} || {Name, Args} <- Calls]
                },
                State};
        {error, Error} ->
            {error, Error, State}
    end.

stage_all(_Stage, []) ->
    ok;
stage_all(Stage, [{Path, Bytes} | Rest]) ->
    case Stage(maps:get(mount_name, #{}, ro), Path, Bytes) of
        ok -> stage_all(Stage, Rest);
        {error, _} = Error -> Error
    end.

decode(_Result, #{raise := decode}) ->
    error(decode_crashed);
decode(#{outcome := returned, values := Values, channels := #{stdout := Out}}, _State) ->
    {ok, #{values => Values, stdout => Out}};
decode(#{outcome := exited, exit := Code}, _State) ->
    {error, wasmtime_worker_error:adapter(exit, ~"the guest exited", #{code => Code})};
decode(#{outcome := trapped, error := Error}, _State) ->
    {error, wasmtime_worker_error:runtime(Error)}.

cleanup(#{raise := cleanup}) ->
    error(cleanup_crashed);
cleanup(State) ->
    notify(State, cleaned),
    ok.

notify(#{notify := Pid, dir := Dir}, What) -> Pid ! {What, Dir};
notify(_State, _What) -> ok.

capabilities(_Artifact) ->
    #{
        execution => reactor,
        input_channels => [typed_args, files],
        result_channels => [typed_result],
        snapshots => unsupported,
        wasi => true
    }.

conformance_fixtures(_Artifact) ->
    #{
        base => #{
            echo => #{call => {~"echo", [41]}},
            failure => #{call => {~"boom", []}},
            runaway => #{call => {~"spin", []}},
            state_change => #{call => {~"bump", []}}
        },
        by_capability => #{}
    }.

classify({ok, _}, _State) -> continue;
classify({error, #{class := exit, status := Code}}, _State) -> {stop, {exited, Code}};
classify({error, _}, _State) -> {stop, trapped}.
