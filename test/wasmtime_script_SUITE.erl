%% wasmtime_script_worker: one request at a time through an adapter, each
%% with its own instance and directory, a deadline and bounded output. The
%% kernel cases use wasmtime_test_adapter; the language cases need the
%% interpreters, found in $WASMTIME_LANG_DIR (qjs.wasm, python.wasm).
-module(wasmtime_script_SUITE).

-export([all/0, groups/0, init_per_suite/1, end_per_suite/1, init_per_group/2, end_per_group/2]).
-export([
    echo_returns_a_result/1,
    a_guest_failure_is_a_worker_error/1,
    the_deadline_stops_a_runaway/1,
    cancel_stops_a_runaway/1,
    a_caller_that_dies_cancels/1,
    no_state_leaks_between_requests/1,
    a_second_submit_is_busy/1,
    await_rules/1,
    an_unawaited_outcome_is_dropped_by_the_next/1,
    dead_worker_answers_with_a_value/1,
    the_request_directory_is_removed/1,
    cleanup_runs_whatever_happens/1,
    staging_is_bounded/1,
    a_writable_mount_needs_a_trusted_worker/1,
    requirements_are_checked/1,
    output_is_bounded/1,
    memory_pages_are_bounded/1,
    an_exit_stops_the_remaining_calls/1,
    a_crashing_adapter_is_an_error/1,
    start_refusals/1,
    errors_have_the_same_structure/1,
    script_v1_framing/1,
    javascript_command/1,
    python_command/1
]).

all() -> [{group, kernel}, {group, languages}].

groups() ->
    [
        {kernel, [parallel], [
            echo_returns_a_result,
            a_guest_failure_is_a_worker_error,
            the_deadline_stops_a_runaway,
            cancel_stops_a_runaway,
            a_caller_that_dies_cancels,
            no_state_leaks_between_requests,
            a_second_submit_is_busy,
            await_rules,
            an_unawaited_outcome_is_dropped_by_the_next,
            dead_worker_answers_with_a_value,
            the_request_directory_is_removed,
            cleanup_runs_whatever_happens,
            staging_is_bounded,
            a_writable_mount_needs_a_trusted_worker,
            requirements_are_checked,
            output_is_bounded,
            memory_pages_are_bounded,
            an_exit_stops_the_remaining_calls,
            a_crashing_adapter_is_an_error,
            start_refusals,
            errors_have_the_same_structure,
            script_v1_framing
        ]},
        {languages, [], [javascript_command, python_command]}
    ].

-define(W, wasmtime_script_worker).
-define(A, wasmtime_test_adapter).

init_per_suite(Config) ->
    case wasmtime_test:needs([compiler, wat, wasi], Config) of
        {skip, _} = Skip ->
            Skip;
        _ ->
            {ok, _} = application:ensure_all_started(erlang_wasmtime),
            Root = filename:join(proplists:get_value(priv_dir, Config), "scratch"),
            ok = application:set_env(erlang_wasmtime, scratch_roots, #{scratch => Root}),
            [{scratch, Root} | Config]
    end.

end_per_suite(_) ->
    application:unset_env(erlang_wasmtime, scratch_roots),
    ok.

init_per_group(_, Config) -> Config.

end_per_group(_, _) -> ok.

start() -> start(#{}).
start(Opts) ->
    {ok, W} = ?W:start_link(?A, Opts),
    W.

echo_returns_a_result(_) ->
    W = start(),
    {ok, #{values := [42]}} = ?W:run(W, #{call => {~"echo", [41]}}),
    {ok, Ref} = ?W:submit(W, #{call => {~"echo", [1]}}),
    {ok, #{values := [2]}} = ?W:await(W, Ref, 5000),
    %% several calls in one request run on one instance
    {ok, #{values := [2]}} = ?W:run(W, #{call => {~"bump", []}, then => {~"bump", []}}),
    ok = ?W:stop(W).

a_guest_failure_is_a_worker_error(_) ->
    W = start(),
    {error, #{class := runtime, kind := runtime_failure, ctx := #{error := #{kind := unreachable}}}} =
        ?W:run(W, #{call => {~"boom", []}}),
    {ok, _} = ?W:run(W, #{}),
    ok = ?W:stop(W).

the_deadline_stops_a_runaway(_) ->
    W = start(#{limits => #{timeout => 100}}),
    T0 = erlang:monotonic_time(millisecond),
    {error, #{class := worker, kind := timeout, ctx := #{timeout := 100}}} =
        ?W:run(W, #{call => {~"spin", []}}),
    true = erlang:monotonic_time(millisecond) - T0 < 2000,
    {ok, #{values := [2]}} = ?W:run(W, #{}),
    ok = ?W:stop(W).

cancel_stops_a_runaway(_) ->
    W = start(#{limits => #{timeout => infinity}}),
    {ok, Ref} = ?W:submit(W, #{call => {~"spin", []}}),
    {error, #{kind := still_running}} = ?W:await(W, Ref, 50),
    ok = ?W:cancel(W, Ref),
    {error, #{class := worker, kind := cancelled}} = ?W:await(W, Ref, 1000),
    {error, #{kind := unknown_ref}} = ?W:cancel(W, Ref),
    {ok, _} = ?W:run(W, #{}),
    ok = ?W:stop(W).

a_caller_that_dies_cancels(_) ->
    W = start(#{limits => #{timeout => infinity}}),
    {Pid, Mon} = spawn_monitor(fun() -> {ok, _} = ?W:submit(W, #{call => {~"spin", []}}) end),
    receive
        {'DOWN', Mon, process, Pid, _} -> ok
    end,
    %% the worker is free again without anyone cancelling
    {ok, #{values := [2]}} = retry_busy(W, #{}, 50),
    ok = ?W:stop(W).

retry_busy(W, Request, N) ->
    case ?W:run(W, Request) of
        {error, #{kind := busy}} when N > 0 ->
            timer:sleep(20),
            retry_busy(W, Request, N - 1);
        Other ->
            Other
    end.

no_state_leaks_between_requests(_) ->
    W = start(),
    {ok, #{values := [1]}} = ?W:run(W, #{call => {~"bump", []}}),
    {ok, #{values := [1]}} = ?W:run(W, #{call => {~"bump", []}}),
    ok = ?W:stop(W).

a_second_submit_is_busy(_) ->
    W = start(#{limits => #{timeout => infinity}}),
    {ok, Ref} = ?W:submit(W, #{call => {~"spin", []}}),
    {error, #{class := worker, kind := busy}} = ?W:submit(W, #{}),
    {error, #{kind := busy}} = ?W:run(W, #{}),
    ok = ?W:cancel(W, Ref),
    ok = ?W:stop(W).

await_rules(_) ->
    W = start(#{limits => #{timeout => infinity}}),
    {error, #{kind := unknown_ref}} = ?W:await(W, make_ref(), 100),
    {ok, Ref} = ?W:submit(W, #{call => {~"spin", []}}),
    Self = self(),
    Waiter = spawn_link(fun() -> Self ! {first, ?W:await(W, Ref, infinity)} end),
    timer:sleep(50),
    {error, #{kind := already_awaited}} = ?W:await(W, Ref, 100),
    ok = ?W:cancel(W, Ref),
    receive
        {first, {error, #{kind := cancelled}}} -> ok
    end,
    false = is_process_alive(Waiter) andalso undefined,
    %% an outcome is given once
    {error, #{kind := unknown_ref}} = ?W:await(W, Ref, 100),
    %% a finite await that gave up leaves the slot free
    {ok, Ref2} = ?W:submit(W, #{call => {~"spin", []}}),
    {error, #{kind := still_running}} = ?W:await(W, Ref2, 20),
    {error, #{kind := still_running}} = ?W:await(W, Ref2, 20),
    ok = ?W:cancel(W, Ref2),
    {error, #{kind := cancelled}} = ?W:await(W, Ref2, 1000),
    ok = ?W:stop(W).

an_unawaited_outcome_is_dropped_by_the_next(_) ->
    W = start(),
    {ok, Ref} = ?W:submit(W, #{call => {~"echo", [1]}}),
    timer:sleep(200),
    %% it survives until someone asks or another request comes
    {ok, Ref2} = retry_submit(W, #{call => {~"echo", [5]}}, 50),
    {error, #{kind := unknown_ref}} = ?W:await(W, Ref, 100),
    {ok, #{values := [6]}} = ?W:await(W, Ref2, 5000),
    ok = ?W:stop(W).

retry_submit(W, Request, N) ->
    case ?W:submit(W, Request) of
        {error, #{kind := busy}} when N > 0 ->
            timer:sleep(20),
            retry_submit(W, Request, N - 1);
        Other ->
            Other
    end.

dead_worker_answers_with_a_value(_) ->
    W = start(),
    ok = ?W:stop(W),
    {error, #{class := worker, kind := no_worker}} = ?W:run(W, #{}),
    {error, #{kind := no_worker}} = ?W:submit(W, #{}),
    {error, #{kind := no_worker}} = ?W:await(W, make_ref(), 100),
    {error, #{kind := no_worker}} = ?W:cancel(W, make_ref()),
    ok.

the_request_directory_is_removed(Config) ->
    W = start(),
    {ok, _} = ?W:run(W, #{notify => self(), files => [{~"a/b.txt", ~"hello"}]}),
    Dir =
        receive
            {prepared, D} -> D
        end,
    receive
        {cleaned, Dir} -> ok
    end,
    false = filelib:is_dir(Dir),
    false = filelib:is_dir(filename:dirname(Dir)),
    true = lists:prefix(proplists:get_value(scratch, Config), binary_to_list(Dir)),
    ok = ?W:stop(W).

cleanup_runs_whatever_happens(_) ->
    W = start(#{limits => #{timeout => 100}}),
    Check = fun(Request, Expect) ->
        Expect(?W:run(W, Request#{notify => self()})),
        Dir =
            receive
                {prepared, D} -> D
            end,
        receive
            {cleaned, Dir} -> ok
        after 2000 -> ct:fail({no_cleanup, Request})
        end,
        false = filelib:is_dir(Dir)
    end,
    Check(#{call => {~"boom", []}}, fun({error, #{kind := runtime_failure}}) -> ok end),
    Check(#{call => {~"spin", []}}, fun({error, #{kind := timeout}}) -> ok end),
    Check(#{raise => decode}, fun({error, #{kind := crashed}}) -> ok end),
    Check(#{files => [{~"../out", ~"x"}]}, fun({error, #{kind := bad_stage_path}}) -> ok end),
    %% a cleanup that crashes does not take the worker with it
    {ok, _} = ?W:run(W, #{raise => cleanup}),
    {ok, _} = ?W:run(W, #{}),
    ok = ?W:stop(W).

staging_is_bounded(_) ->
    W = start(#{limits => #{max_staged_bytes => 10, max_staged_files => 2}}),
    Bad = fun(Path) ->
        {error, #{class := worker, kind := bad_stage_path}} =
            ?W:run(W, #{files => [{Path, ~"x"}], needs => #{staged_bytes => 0, staged_files => 0}})
    end,
    [Bad(P) || P <- [~"../x", ~"/etc/x", ~"a/../../x", ~"a//b", <<>>, ~"./x"]],
    {ok, _} = ?W:run(W, #{files => [{~"a", ~"12345"}, {~"b/c", ~"12345"}]}),
    %% declared honestly, it is refused before anything is made
    {error, #{kind := insufficient_limit, ctx := #{limit := max_staged_bytes}}} =
        ?W:run(W, #{files => [{~"a", ~"12345678901"}]}),
    {error, #{kind := insufficient_limit, ctx := #{limit := max_staged_files}}} =
        ?W:run(W, #{files => [{~"a", <<>>}, {~"b", <<>>}, {~"c", <<>>}]}),
    %% declared falsely, the stage function still holds the bound
    Lie = #{needs => #{staged_bytes => 0, staged_files => 0}},
    {error, #{kind := insufficient_limit, ctx := #{limit := staged}}} =
        ?W:run(W, Lie#{files => [{~"a", ~"12345678901"}]}),
    {error, #{kind := insufficient_limit, ctx := #{limit := staged}}} =
        ?W:run(W, Lie#{files => [{~"a", <<>>}, {~"b", <<>>}, {~"c", <<>>}]}),
    ok = ?W:stop(W).

a_writable_mount_needs_a_trusted_worker(_) ->
    W = start(),
    {error, #{kind := insufficient_limit, ctx := #{limit := trusted}}} = ?W:run(W, #{mount => write}),
    ok = ?W:stop(W),
    T = start(#{trusted => true}),
    {ok, _} = ?W:run(T, #{mount => write}),
    ok = ?W:stop(T).

requirements_are_checked(_) ->
    W = start(#{limits => #{timeout => 1000, max_memory_pages => 16, max_request_bytes => 10}}),
    Needs = fun(N) -> ?W:run(W, #{needs => N}) end,
    {error, #{
        kind := insufficient_limit, ctx := #{limit := timeout, needed := 5000, allowed := 1000}
    }} =
        Needs(#{min_timeout => 5000}),
    {error, #{kind := insufficient_limit, ctx := #{limit := max_memory_pages}}} =
        Needs(#{min_memory_pages => 17}),
    {error, #{kind := insufficient_limit, ctx := #{limit := max_request_bytes}}} =
        Needs(#{request_bytes => 11}),
    {ok, _} = Needs(#{min_timeout => 1000, min_memory_pages => 16, request_bytes => 10}),
    {error, #{class := adapter, kind := adapter_failure}} = ?W:run(W, not_a_map),
    ok = ?W:stop(W).

output_is_bounded(_) ->
    W = start(#{limits => #{max_output_bytes => 64}}),
    {ok, #{stdout := <<"0123456789abcdef", _/binary>> = Out}} = ?W:run(W, #{call => {~"print", [4]}}),
    64 = byte_size(Out),
    {error, #{class := worker, kind := output_limit, ctx := #{limit := 64}}} =
        ?W:run(W, #{call => {~"print", [5]}}),
    ok = ?W:stop(W).

memory_pages_are_bounded(_) ->
    W = start(#{limits => #{max_memory_pages => 4}}),
    {ok, #{values := [1]}} = ?W:run(W, #{call => {~"grow", [3]}}),
    {ok, #{values := [-1]}} = ?W:run(W, #{call => {~"grow", [4]}}),
    ok = ?W:stop(W).

an_exit_stops_the_remaining_calls(_) ->
    W = start(),
    {error, #{class := adapter, kind := exit, ctx := #{code := 3}}} =
        ?W:run(W, #{call => {~"exit", [3]}, then => {~"boom", []}}),
    ok = ?W:stop(W).

a_crashing_adapter_is_an_error(_) ->
    W = start(),
    [
        {error, #{class := worker, kind := crashed}} = ?W:run(W, #{raise => Where})
     || Where <- [requirements, prepare, decode]
    ],
    {ok, _} = ?W:run(W, #{}),
    ok = ?W:stop(W).

start_refusals(_) ->
    process_flag(trap_exit, true),
    {error, {unknown_root, nowhere, [scratch]}} = ?W:start_link(?A, #{root => nowhere}),
    {error, {invalid_limits, [max_depth]}} = ?W:start_link(?A, #{limits => #{max_depth => 10}}),
    {error, {artifact_failed, #{class := adapter}}} = ?W:start_link(?A, #{fail => true}),
    {error, {artifact_failed, #{kind := adapter_failure}}} =
        ?W:start_link(wasmtime_javascript_command, #{}),
    {error, {artifact_failed, #{ctx := #{reason := enoent}}}} =
        ?W:start_link(wasmtime_python_command, #{path => "/no/such/python.wasm"}),
    {ok, Named} = ?W:start_link({local, wasmtime_script_named}, ?A, #{}),
    {ok, #{values := [2]}} = ?W:run(wasmtime_script_named, #{}),
    ok = ?W:stop(Named),
    #{timeout := 5000, max_output_bytes := _, max_staged_files := 64, max_memory_pages := 256} =
        ?W:default_limits(),
    process_flag(trap_exit, false),
    ok.

errors_have_the_same_structure(_) ->
    W = start(#{limits => #{timeout => 100, max_output_bytes => 16}}),
    Errors = [
        ?W:run(W, R)
     || R <- [
            #{call => {~"boom", []}},
            #{call => {~"spin", []}},
            #{call => {~"exit", [1]}},
            #{call => {~"print", [2]}},
            #{raise => prepare},
            #{files => [{~"../x", ~"x"}]},
            #{needs => #{min_timeout => 1000}},
            not_a_map
        ]
    ],
    [true = wasmtime_worker_error:is_error(E) || {error, E} <- Errors],
    8 = length([E || {error, E} <- Errors]),
    Kinds = lists:usort([wasmtime_worker_error:kind_of(E) || {error, E} <- Errors]),
    true = Kinds -- wasmtime_worker_error:kinds() =:= [],
    [adapter, runtime, worker] =
        lists:usort([wasmtime_worker_error:class_of(E) || {error, E} <- Errors]),
    false = wasmtime_worker_error:is_error(#{
        class => worker, kind => exit, message => ~"", ctx => #{}
    }),
    false = wasmtime_worker_error:is_error(not_an_error),
    ok = ?W:stop(W).

script_v1_framing(_) ->
    V = wasmtime_script_v1,
    M = V:marker(),
    32 = byte_size(M),
    true = M =/= V:marker(),
    Frame = fun(Json) -> <<"printed\n", M/binary, Json/binary, "\n">> end,
    {ok, #{result := #{~"a" := 1}, stdout := ~"printed\n"}} =
        V:decode_combined(Frame(~"{\"ok\":{\"a\":1}}"), M),
    %% the last marker wins
    {ok, #{result := 2}} = V:decode_combined(
        <<M/binary, "{\"ok\":1}\n", M/binary, "{\"ok\":2}">>, M
    ),
    {error, ~"no_result", _} = V:decode_combined(~"just output", M),
    {error, ~"bad_result", _} = V:decode_combined(Frame(~"not json"), M),
    {error, ~"bad_result", _} = V:decode_combined(Frame(~"{\"other\":1}"), M),
    {error, ~"bad_result", _} = V:decode_combined(M, M),
    {error, ~"exception", ~"boom"} =
        V:decode_combined(Frame(~"{\"error\":{\"code\":\"exception\",\"message\":\"boom\"}}"), M),
    {error, ~"bad_result", _} =
        V:decode_combined(Frame(~"{\"error\":{\"code\":\"mine\",\"message\":\"x\"}}"), M),
    ~"{\"k\":[1,2]}" = V:encode_context(#{k => [1, 2]}),
    <<_, _/binary>> = V:boot(js),
    <<_, _/binary>> = V:boot(py),
    ok.

%% ---------------------------------------------------------------- languages

engine(Name) ->
    case os:getenv("WASMTIME_LANG_DIR") of
        false ->
            {skip, "set WASMTIME_LANG_DIR to a directory holding " ++ Name};
        Dir ->
            Path = filename:join(Dir, Name),
            case filelib:is_regular(Path) of
                true -> {ok, Path};
                false -> {skip, "no " ++ Path}
            end
    end.

javascript_command(_) ->
    case engine("qjs.wasm") of
        {skip, _} = Skip ->
            Skip;
        {ok, Path} ->
            {ok, W} = ?W:start_link(wasmtime_javascript_command, #{path => Path}),
            {ok, #{result := #{~"answer" := 42}, stdout := ~"hello\n"}} = ?W:run(
                W,
                ~"export function main(c) { console.log('hello'); return {answer: c.value + 1}; }",
                #{~"value" => 41}
            ),
            conformance(W, wasmtime_javascript_command, #{path => Path}),
            ok = ?W:stop(W)
    end.

python_command(_) ->
    case engine("python.wasm") of
        {skip, _} = Skip ->
            Skip;
        {ok, Path} ->
            Opts = #{path => Path, limits => #{timeout => 60_000, max_memory_pages => 4096}},
            {ok, W} = ?W:start_link(wasmtime_python_command, Opts),
            {ok, #{result := #{~"answer" := 42}}} = ?W:run(
                W, ~"def main(c):\n    return {\"answer\": c[\"value\"] + 1}\n", #{~"value" => 41}
            ),
            ok = ?W:stop(W)
    end.

%% The adapter's own fixtures, each with the outcome the contract asks for.
conformance(W, Adapter, Opts) ->
    {ok, Artifact} = Adapter:artifact(Opts),
    #{base := #{echo := Echo, failure := Failure, runaway := Runaway, state_change := State}} =
        Adapter:conformance_fixtures(Artifact),
    {ok, #{result := _}} = ?W:run(W, Echo),
    {error, #{class := adapter, kind := adapter_failure, ctx := #{code := ~"exception"}} = E} =
        ?W:run(W, Failure),
    true = wasmtime_worker_error:is_error(E),
    {ok, #{result := First}} = ?W:run(W, State),
    {ok, #{result := First}} = ?W:run(W, State),
    {ok, Short} = ?W:start_link(Adapter, Opts#{limits => #{timeout => 1000}}),
    {error, #{class := worker, kind := timeout}} = ?W:run(Short, Runaway),
    ok = ?W:stop(Short).
