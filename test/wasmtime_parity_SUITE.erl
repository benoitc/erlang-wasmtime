%% Parity with erlang_wasm. The manifest says where every public function of
%% erlang_wasm's supported modules stands; notes/erlang-wasm-parity.md is the
%% same table for people. The behaviour cases pin the calls that answer as
%% erlang_wasm does.
%%
%% With ERLANG_WASM_DIR naming a built erlang_wasm checkout, the manifest is
%% also checked against its exports and the same programs are run on both.
-module(wasmtime_parity_SUITE).
-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([
    here_is_exported/1,
    pending_is_not_exported_yet/1,
    deferred_is_documented/1,
    manifest_covers_erlang_wasm/1,
    errors_are_erlang_wasm_errors/1,
    start_section_is_bounded/1,
    wasi_env_map_and_clock_list/1,
    host_context_and_module_function/1,
    ignored_options_are_refused/1,
    proc_exit_is_a_trap/1,
    memory_size_in_pages/1,
    error_constructors/1,
    same_errors_on_both_runtimes/1
]).

%% Called as a {Module, Function} host function.
-export([double/2]).

all() ->
    [{group, manifest}, {group, behaviour}, {group, both}].

groups() ->
    [
        {manifest, [], [
            here_is_exported,
            pending_is_not_exported_yet,
            deferred_is_documented,
            manifest_covers_erlang_wasm
        ]},
        {behaviour, [], [
            errors_are_erlang_wasm_errors,
            start_section_is_bounded,
            wasi_env_map_and_clock_list,
            host_context_and_module_function,
            ignored_options_are_refused,
            proc_exit_is_a_trap,
            memory_size_in_pages,
            error_constructors
        ]},
        {both, [], [same_errors_on_both_runtimes]}
    ].

init_per_suite(Config) -> Config.
end_per_suite(_) -> ok.

init_per_group(behaviour, Config) ->
    wasmtime_test:needs([compiler, wat], Config);
init_per_group(both, Config) ->
    case erlang_wasm_ebin() of
        false ->
            {skip, "set ERLANG_WASM_DIR to a built erlang_wasm checkout"};
        Ebin ->
            true = code:add_pathz(Ebin),
            wasmtime_test:needs([compiler, wat], Config)
    end;
init_per_group(_, Config) ->
    Config.

end_per_group(_, _) -> ok.

%% ----------------------------------------------------------------- manifest

%% {erlang_wasm's module, functions, where they stand}:
%% {here, Module}: exported by Module under the same name and arity.
%% {phase, N, Module}: planned for phase N, not exported yet.
%% {deferred, Phrase}: not planned; docs/features.md says why, under a
%% heading holding Phrase.
manifest() ->
    [
        {wasm,
            [
                {acquire, 1},
                {call, 3},
                {call, 4},
                {compile, 1},
                {compile, 2},
                {destroy, 1},
                {exports, 1},
                {format_error, 1},
                {func_type_of, 2},
                {func_types_of, 1},
                {get_global, 2},
                {instantiate, 2},
                {instantiate, 3},
                {load, 1},
                {load, 2},
                {load_file, 1},
                {load_snapshot, 2},
                {memory_size, 1},
                {pin, 2},
                {read_memory, 3},
                {release, 1},
                {release, 2},
                {release_all, 1},
                {restore, 3},
                {save_snapshot, 2},
                {snapshot, 1},
                {snapshot, 2},
                {snapshot_info, 1},
                {unload, 1},
                {validate, 1},
                {write_memory, 3}
            ],
            {here, wasmtime}},
        {wasm, [{call_func, 3}, {extern, 2}], {phase, 2, wasmtime}},
        {wasm_error,
            [
                {add_context, 2},
                {capture, 1},
                {capture, 2},
                {exhaustion, 1},
                {exhaustion, 2},
                {format, 1},
                {invalid, 2},
                {invalid, 3},
                {is_error, 1},
                {link_error, 2},
                {link_error, 3},
                {malformed, 2},
                {malformed, 3},
                {trap, 1},
                {trap, 2}
            ],
            {here, wasmtime_error}},
        {wasm_limits, [{default, 0}, {merge, 2}, {trusted, 0}, {untrusted, 0}, {validate, 1}],
            {here, wasmtime_limits}},
        {wasm_engine, [{page_limit, 0}, {pages_in_use, 0}, {set_page_limit, 1}, {stats, 0}],
            {phase, 7, wasmtime_engine}},
        {wasm_component,
            [
                {host_drop, 1},
                {host_get, 1},
                {host_live, 0},
                {host_new, 2},
                {host_new, 3},
                {host_update, 2}
            ],
            {here, wasmtime_component}},
        {wasm_component,
            [
                {call, 4},
                {call_async, 4},
                {call_async, 5},
                {decode, 1},
                {destroy, 1},
                {destroy, 2},
                {drop_resource, 3},
                {exports, 1},
                {import_fun, 2},
                {instantiate, 1},
                {instantiate, 2},
                {instantiate, 3},
                {prepare, 1}
            ],
            {phase, 2, wasmtime_component}},
        {wasm_component, [{pump, 2}, {start_async, 4}, {start_async, 5}],
            {phase, 6, wasmtime_component}},
        {wasm_component, [{acquire, 1}, {release, 1}, {restore, 3}, {snapshot, 2}],
            {deferred, "`preinit/3` for components"}},
        {wasi, [{imports, 1}, {run, 1}, {run, 2}], {phase, 2, wasmtime_wasi}},
        {wasi_preview1, [{exit_code, 1}], {phase, 2, wasmtime_wasi_preview1}},
        {wasi_preview1,
            [
                {close_all, 1},
                {default_config, 0},
                {imports, 1},
                {imports, 2},
                {snapshot_hook, 0}
            ],
            {deferred, "WASI import maps"}},
        {wasi_preview2, [{run_command, 2}, {run_command, 3}], {phase, 2, wasmtime_wasi_preview2}},
        {wasi_preview2, [{run_serve, 3}], {phase, 4, wasmtime_wasi_preview2}},
        {wasi_preview2,
            [
                {cli_exit, 0},
                {clocks, 0},
                {environment, 0},
                {environment, 3},
                {filesystem, 1},
                {imports, 0},
                {io, 0},
                {io, 1},
                {random, 0},
                {sockets, 1},
                {command, 1},
                {serve, 2},
                {run_command_with, 4},
                {run_serve_with, 5}
            ],
            {deferred, "WASI import maps"}},
        {wasi_preview3, [{run_command, 3}], {phase, 2, wasmtime_wasi_preview3}},
        {wasi_preview3, [{run_serve, 3}, {run_serve, 4}], {phase, 4, wasmtime_wasi_preview3}},
        {wasi_preview3,
            [
                {cli, 1},
                {clocks, 0},
                {command, 1},
                {random, 0},
                {serve_imports, 2},
                {run_serve_stream, 5}
            ],
            {deferred, "WASI import maps"}},
        {wasi_http_listener, [{address, 1}, {start, 1}, {stop, 1}],
            {phase, 4, wasmtime_http_listener}},
        {wasi_http_h1, [{request, 2}], {phase, 4, wasmtime_http_h1}},
        {wasi_http_h2, [{request, 2}], {deferred, "HTTP/2"}},
        {wasi_http, [{http, 1}], {deferred, "WASI import maps"}},
        {wasi_nn, [{imports, 1}], {phase, 7, wasmtime_wasi_nn}},
        {wasm_instance_worker,
            [{call, 3}, {call, 4}, {info, 1}, {start_link, 1}, {start_link, 2}, {stop, 1}],
            {here, wasmtime_instance_worker}},
        {wasm_actor, [{send, 2}, {start_link, 2}], {phase, 2, wasmtime_actor}},
        {wasm_script_worker,
            [
                {await, 3},
                {cancel, 2},
                {default_limits, 0},
                {run, 2},
                {run, 3},
                {start_link, 2},
                {start_link, 3},
                {stop, 1},
                {submit, 2},
                {submit, 3}
            ],
            {here, wasmtime_script_worker}},
        {wasm_script_worker, [{channel_write, 2}, {cleanup_requests, 0}, {cleanup_stats, 0}],
            {phase, 5, wasmtime_script_worker}},
        {wasm_worker_error,
            [
                {adapter, 3},
                {class_of, 1},
                {is_error, 1},
                {kind_of, 1},
                {kinds, 0},
                {runtime, 1},
                {runtime, 2},
                {worker, 3}
            ],
            {here, wasmtime_worker_error}},
        {wasm_javascript_command, adapter(), {here, wasmtime_javascript_command}},
        {wasm_python_command, adapter(), {here, wasmtime_python_command}},
        {wasm_javascript, [{defaults, 1}, {snapshot_capability, 1} | adapter()],
            {phase, 5, wasmtime_javascript}},
        {wasm_python, [{defaults, 1}, {limits, 0}, {snapshot_capability, 1} | adapter()],
            {phase, 5, wasmtime_python}},
        {wasm_lua, [{defaults, 1}, {limits, 0}, {snapshot_capability, 1} | adapter()],
            {phase, 5, wasmtime_lua}}
    ].

adapter() ->
    [
        {artifact, 1},
        {capabilities, 1},
        {classify, 2},
        {cleanup, 1},
        {conformance_fixtures, 1},
        {decode, 2},
        {prepare, 3},
        {requirements, 2}
    ].

%% Exports of a supported module that are not part of its supported surface.
internal(wasm) ->
    [{check_module_bytes, 1}, {extern_sibling, 2}];
internal(wasm_engine) ->
    all_but([{page_limit, 0}, {pages_in_use, 0}, {set_page_limit, 1}, {stats, 0}]);
internal(wasm_component) ->
    [{hold, 1}, {source, 1}];
internal(wasi_preview2) ->
    [
        {blocking_read_stream, 2},
        {check_write, 1},
        {close_resource, 1},
        {command_mounts, 1},
        {datagram_allowed, 3},
        {host_remake, 1},
        {monotonic_now, 0},
        {new_output_stream, 1},
        {next_sleep_ms, 1},
        {peer_matches, 3},
        {permit_write, 2},
        {poll, 1},
        {random_bytes, 1},
        {serve_options, 1},
        {snapshot_hooks, 0},
        {write_stream, 2}
    ];
internal(wasi_preview3) ->
    [{host_remake, 1}, {snapshot_hooks, 0}];
internal(wasi_http) ->
    all_but([{http, 1}]);
internal(wasi_nn) ->
    [{check_tensor, 1}, {close_resource, 1}];
internal(wasi_http_listener) ->
    [{serve_request, 6}];
internal(wasm_script_worker) ->
    [{capture_heap_words, 2}, {consumed, 3}, {runner_heap_words, 2}, {withdraw_waiter, 3}];
internal(_) ->
    [].

all_but(Kept) -> {all_but, Kept}.

here_is_exported(_) ->
    Missing = [
        {Module, F}
     || {_, Functions, {here, Module}} <- manifest(), F <- Functions, not exported(Module, F)
    ],
    ?assertEqual([], Missing).

pending_is_not_exported_yet(_) ->
    Done = [
        {Module, F}
     || {_, Functions, {phase, _, Module}} <- manifest(), F <- Functions, exported(Module, F)
    ],
    %% move these to `here`, and update notes/erlang-wasm-parity.md
    ?assertEqual([], Done).

exported(Module, {Function, Arity}) ->
    _ = code:ensure_loaded(Module),
    erlang:function_exported(Module, Function, Arity).

deferred_is_documented(_) ->
    Src = filename:dirname(proplists:get_value(source, wasmtime:module_info(compile))),
    {ok, Features} = file:read_file(filename:join([Src, "..", "docs", "features.md"])),
    [_, Deferred] = binary:split(Features, ~"\n## Deferred\n"),
    Missing = [
        Phrase
     || {_, _, {deferred, Phrase}} <- manifest(),
        binary:match(Deferred, unicode:characters_to_binary(Phrase)) =:= nomatch
    ],
    ?assertEqual([], lists:usort(Missing)).

manifest_covers_erlang_wasm(_) ->
    case erlang_wasm_ebin() of
        false ->
            {skip, "set ERLANG_WASM_DIR to a built erlang_wasm checkout"};
        Ebin ->
            Modules = lists:usort([M || {M, _, _} <- manifest()]),
            Unknown = [{M, F} || M <- Modules, F <- unlisted(Ebin, M)],
            ?assertEqual([], Unknown)
    end.

unlisted(Ebin, Module) ->
    {ok, {_, [{exports, Exports}]}} =
        beam_lib:chunks(filename:join(Ebin, atom_to_list(Module)), [exports]),
    Callbacks = [
        {init, 1},
        {handle_call, 3},
        {handle_cast, 2},
        {handle_info, 2},
        {handle_continue, 2},
        {terminate, 2},
        {module_info, 0},
        {module_info, 1},
        {behaviour_info, 1}
    ],
    Listed = lists:append([Fs || {M, Fs, _} <- manifest(), M =:= Module]),
    case internal(Module) of
        {all_but, Kept} -> Kept -- Exports;
        Internal -> Exports -- (Callbacks ++ Internal ++ Listed)
    end.

erlang_wasm_ebin() ->
    case os:getenv("ERLANG_WASM_DIR") of
        false -> false;
        Dir -> filename:join([Dir, "_build", "default", "lib", "wasm", "ebin"])
    end.

%% ---------------------------------------------------------------- behaviour

failing() ->
    ~"""
    (module
      (import "env" "f" (func $f (param i32) (result i32)))
      (memory (export "memory") 1)
      (global (export "g") i32 (i32.const 1))
      (func (export "unreachable") unreachable)
      (func (export "div") (param i32) (result i32) i32.const 1 local.get 0 i32.div_s)
      (func (export "load") (param i32) (result i32) local.get 0 i32.load)
      (func $deep (export "deep") call $deep)
      (func (export "host") (param i32) (result i32) local.get 0 call $f))
    """.

%% The calls both runtimes answer with the same class and kind.
failures() ->
    [
        {~"unreachable", [], trap, unreachable},
        {~"div", [0], trap, integer_divide_by_zero},
        {~"load", [65536], trap, out_of_bounds_memory_access},
        {~"deep", [], exhaustion, call_stack_exhausted},
        {~"nope", [], link, unknown_export},
        {~"g", [], link, not_a_function},
        {~"div", [], link, argument_arity},
        {~"div", [1.5], link, argument_type},
        {~"host", [1], trap, host_error}
    ].

double(#{instance := Inst}, [X]) ->
    {ok, 1} = wasmtime:memory_size(Inst),
    {ok, [X * 2]}.

refuse() -> fun(_, _) -> {trap, refused} end.

errors_are_erlang_wasm_errors(_) ->
    {ok, Mod} = wasmtime:compile({wat, failing()}),
    {ok, Inst} = wasmtime:instantiate(Mod, #{{~"env", ~"f"} => refuse()}, #{}),
    [
        begin
            {error, Error} = wasmtime:call(Inst, Name, Args),
            ?assertMatch(#{class := Class, kind := Kind, msg := <<_/binary>>, ctx := #{}}, Error),
            true = wasmtime_error:is_error(Error)
        end
     || {Name, Args, Class, Kind} <- failures()
    ],
    {error, #{class := link, kind := unknown_import, ctx := #{module := ~"env", name := ~"f"}}} =
        wasmtime:instantiate(Mod),
    {error, #{class := link, kind := bad_import}} =
        wasmtime:instantiate(Mod, #{{~"env", ~"f"} => not_a_fun}, #{}),
    ok.

start_section_is_bounded(_) ->
    {ok, Mod} = wasmtime:compile({wat, ~"(module (func $s (loop br 0)) (start $s))"}),
    {error, #{class := exhaustion, kind := timeout}} =
        wasmtime:instantiate(Mod, #{}, #{timeout => 200}),
    ok.

wasi_env_map_and_clock_list(Config) ->
    case wasmtime_test:needs([wasi], Config) of
        {skip, _} = Skip ->
            Skip;
        _ ->
            {ok, Mod} = wasmtime:compile({wat, wasmtime_test:wasi_argv_wat()}),
            {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{
                wasi => #{
                    env => #{~"A" => ~"1"},
                    clocks => [monotonic],
                    random => strong,
                    net => none,
                    stdout => capture
                }
            }),
            {ok, _} = wasmtime:call(Inst, ~"env", []),
            {ok, {Out, _, _}} = wasmtime:read_output(Inst),
            ?assertMatch({_, _}, binary:match(Out, ~"A=1")),
            {ok, _} = wasmtime:instantiate(Mod, #{}, #{
                wasi => #{clocks => [realtime, monotonic]}
            }),
            ok
    end.

host_context_and_module_function(_) ->
    {ok, Mod} = wasmtime:compile({wat, failing()}),
    {ok, Inst} = wasmtime:instantiate(Mod, #{{~"env", ~"f"} => {?MODULE, double}}, #{}),
    {ok, [42]} = wasmtime:call(Inst, ~"host", [21]),
    Remember = fun(Ctx, [X]) ->
        ok = wasmtime:write_memory(Ctx, 0, ~"ctx"),
        {ok, ~"ctx"} = wasmtime:read_memory(Ctx, 0, 3),
        {ok, 1} = wasmtime:memory_size(Ctx),
        {ok, [X]}
    end,
    {ok, Other} = wasmtime:instantiate(Mod, #{{~"env", ~"f"} => Remember}, #{}),
    {ok, [7]} = wasmtime:call(Other, ~"host", [7]),
    {ok, Failing} = wasmtime:instantiate(Mod, #{{~"env", ~"f"} => refuse()}, #{}),
    {error, #{ctx := #{reason := refused, host := {~"env", ~"f"}}}} =
        wasmtime:call(Failing, ~"host", [1]),
    Raising = fun(_, _) -> wasmtime_error:exhaustion(host_call_limit) end,
    {ok, Limited} = wasmtime:instantiate(Mod, #{{~"env", ~"f"} => Raising}, #{}),
    {error, #{class := exhaustion, kind := host_call_limit}} =
        wasmtime:call(Limited, ~"host", [1]),
    ok.

ignored_options_are_refused(_) ->
    {ok, Mod} = wasmtime:compile({wat, ~"(module (func (export \"f\")))"}),
    Refused = fun(Kind, Opts) ->
        {error, #{class := link, kind := Kind}} = wasmtime:instantiate(Mod, #{}, Opts)
    end,
    [
        Refused(unsupported_option, #{Key => true})
     || Key <- [link, snapshot_hooks, compile, compile_quality, compile_after, resource_limit]
    ],
    Refused(unsupported_option, #{wasi => #{random => {seed, 1}}}),
    Refused(unsupported_option, #{wasi => #{net => #{connect => []}}}),
    Refused(unsupported_option, #{wasi => #{clocks => [realtime]}}),
    Refused(unsupported_option, #{wasi => #{preopens => []}}),
    {ok, Inst} = wasmtime:instantiate(Mod),
    {error, #{class := link, kind := invalid_limits, ctx := #{keys := [max_depth]}}} =
        wasmtime:call(Inst, ~"f", [], #{max_depth => 10}),
    {error, #{class := link, kind := invalid_limits}} =
        wasmtime:call(Inst, ~"f", [], #{max_host_calls => 10}),
    ok.

proc_exit_is_a_trap(Config) ->
    case wasmtime_test:needs([wasi], Config) of
        {skip, _} = Skip ->
            Skip;
        _ ->
            {ok, Mod} = wasmtime:compile(
                {wat,
                    ~"""
                    (module
                      (import "wasi_snapshot_preview1" "proc_exit" (func $exit (param i32)))
                      (memory (export "memory") 1)
                      (func (export "exit") (param i32) local.get 0 call $exit))
                    """}
            ),
            {ok, Inst} = wasmtime:instantiate(Mod, #{}, #{wasi => #{}}),
            {error, #{class := trap, kind := host_error, ctx := #{wasi_exit := 0}}} =
                wasmtime:call(Inst, ~"exit", [0]),
            ok
    end.

memory_size_in_pages(_) ->
    {ok, Mod} = wasmtime:compile({wat, ~"(module (memory (export \"memory\") 3))"}),
    {ok, Inst} = wasmtime:instantiate(Mod),
    {ok, 3} = wasmtime:memory_size(Inst),
    ok.

error_constructors(_) ->
    {error, #{class := trap, kind := unreachable, msg := ~"unreachable", ctx := #{at := 1}}} =
        wasmtime_error:capture(fun() -> wasmtime_error:trap(unreachable) end, #{at => 1}),
    {error, #{class := malformed, kind := internal}} =
        wasmtime_error:capture(fun() -> error(boom) end),
    Line = iolist_to_binary(
        wasmtime:format_error(
            wasmtime_error:new(link, unknown_export, ~"unknown export", #{name => ~"f"})
        )
    ),
    ?assertMatch({_, _}, binary:match(Line, ~"link: unknown export (unknown_export)")),
    false = wasmtime_error:is_error(#{class => other, kind => k, msg => ~"", ctx => #{}}),
    ok.

%% --------------------------------------------------------------------- both

%% The same module and calls on erlang_wasm and here.
same_errors_on_both_runtimes(_) ->
    Imports = #{{~"env", ~"f"} => refuse()},
    Run = fun(Runtime) ->
        {ok, Mod} = Runtime:compile({wat, failing()}),
        {ok, Inst} = Runtime:instantiate(Mod, Imports, #{}),
        [
            begin
                {error, #{class := Class, kind := Kind}} = Runtime:call(Inst, Name, Args),
                {Name, Args, Class, Kind}
            end
         || {Name, Args, _, _} <- failures()
        ]
    end,
    Theirs = Run(wasm),
    ?assertEqual(Theirs, Run(wasmtime)).
