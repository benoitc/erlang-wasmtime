-module(wasmtime_script_worker).
-moduledoc """
Runs requests through an adapter, one at a time, each in a fresh instance
with its own directory, a deadline and bounded output. erlang_wasm's
`wasm_script_worker`, for this runtime.

```erlang
{ok, W} = wasmtime_script_worker:start_link(wasmtime_javascript_command, #{path => "qjs.wasm"}),
{ok, #{result := #{~"answer" := 42}}} =
    wasmtime_script_worker:run(W, ~"export function main(c) { return {answer: c.value + 1}; }", #{
        ~"value" => 41
    }).
```

`run/2,3` waits for the answer. `submit/2,3`, `await/3` and `cancel/2` do
the same work without your process waiting. A worker holds one request at
a time: a second `submit` answers `kind => busy`. Run a pool for
parallelism.

Each request runs in a process of its own, the runner, which makes the
instance, calls the guest and decodes what happened. The worker holds the
deadline: a runner still alive after it is killed, which interrupts the
guest. Whatever happens to the runner, the request's directory is removed
and the adapter's `cleanup/1` runs.

See [scripting](scripting.md) for the options and what is not here.
""".

-behaviour(gen_server).

-export([start_link/2, start_link/3, stop/1]).
-export([submit/2, submit/3, await/3, cancel/2, run/2, run/3]).
-export([default_limits/0, roots/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% The ceilings a worker starts with, over wasmtime_limits:untrusted/0.
%% docs/scripting.md lists them; docs/design.md says why.
-define(WORKER_LIMITS, #{
    timeout => 5_000,
    max_output_bytes => 1_048_576,
    max_request_bytes => 1_048_576,
    max_staged_bytes => 8_388_608,
    max_staged_files => 64
}).
%% How long past the deadline the worker waits for the runner, which
%% interrupts the guest at the deadline itself, before killing it.
-define(KILL_GRACE, 500).

-record(state, {
    adapter :: module(),
    artifact :: term(),
    limits :: map(),
    trusted :: boolean(),
    root :: binary(),
    %% in flight, at most one
    ref :: undefined | reference(),
    runner :: undefined | pid(),
    rmon :: undefined | reference(),
    smon :: undefined | reference(),
    timer :: undefined | reference(),
    dir :: undefined | binary(),
    %% what cleanup/1 gets, once prepare/3 has answered
    astate = none :: none | {state, term()},
    %% completed, kept until its waiter has it
    done_ref :: undefined | reference(),
    done_outcome :: term(),
    %% at most one waiter
    waiter :: undefined | {gen_server:from() | replied, reference()},
    discarded = 0 :: non_neg_integer()
}).

-type state() :: #state{}.
-type outcome() :: wasmtime_worker_adapter:outcome().
-type worker_error() :: wasmtime_worker_error:worker_error().

%% --------------------------------------------------------------------- api

-doc """
Start a worker for one adapter.

`Opts` takes `root` (a key of `scratch_roots`, `scratch` when left out),
`trusted` (whether a writable mount is allowed, `false` by default) and a
`limits` map merged over `default_limits/0`. All of it is also handed to
`Adapter:artifact/1`, which is where an adapter finds its `path`.

Refused with `{error, {unknown_root, Root, Known}}` for a root the node
does not have, `{error, {invalid_limits, Keys}}` for limits that cannot
apply, and `{error, {artifact_failed, Error}}` when the adapter cannot load
what it runs.
""".
-spec start_link(module(), map()) -> {ok, pid()} | {error, term()}.
start_link(Adapter, Opts) when is_atom(Adapter), is_map(Opts) ->
    gen_server:start_link(?MODULE, {Adapter, Opts}, []).

-spec start_link(gen_server:server_name(), module(), map()) -> {ok, pid()} | {error, term()}.
start_link(Name, Adapter, Opts) when is_atom(Adapter), is_map(Opts) ->
    gen_server:start_link(Name, ?MODULE, {Adapter, Opts}, []).

-spec stop(gen_server:server_ref()) -> ok.
stop(W) -> gen_server:stop(W).

-doc "Accept a request. Answers once its runner is started; `kind => busy` while another runs.".
-spec submit(gen_server:server_ref(), term()) -> {ok, reference()} | {error, worker_error()}.
submit(W, Request) -> guard(W, {submit, Request, self()}).

-doc "`submit/2` with `#{source => Source, context => Context}`, the request every shipped adapter takes.".
-spec submit(gen_server:server_ref(), binary(), term()) ->
    {ok, reference()} | {error, worker_error()}.
submit(W, Source, Context) -> submit(W, #{source => Source, context => Context}).

-doc """
Wait for an outcome.

`AwaitTimeout` bounds your wait and nothing else: the request keeps running
under its own deadline and `kind => still_running` says so. `cancel/2` is
what stops it. One process waits for a request at a time (`already_awaited`
otherwise), and an outcome is given once (`unknown_ref` afterwards).
""".
-spec await(gen_server:server_ref(), reference(), timeout()) -> outcome().
await(W, Ref, AwaitTimeout) ->
    Token = make_ref(),
    try gen_server:call(W, {await, Ref, Token}, AwaitTimeout) of
        {outcome, Outcome} ->
            gen_server:cast(W, {consumed, Ref, Token}),
            Outcome;
        {error, _} = Error ->
            Error
    catch
        exit:{timeout, _} ->
            %% The worker may have answered just as this caller gave up.
            case guard(W, {withdraw, Ref, Token}) of
                {ok, Outcome} ->
                    gen_server:cast(W, {consumed, Ref, Token}),
                    Outcome;
                _ ->
                    {error,
                        wasmtime_worker_error:worker(still_running, ~"gave up waiting", #{
                            waited => AwaitTimeout
                        })}
            end;
        exit:{noproc, _} ->
            {error, no_worker()};
        exit:{Reason, _} ->
            {error, worker_died(Reason)}
    end.

-doc "Stop a request. Its outcome is `kind => cancelled`.".
-spec cancel(gen_server:server_ref(), reference()) -> ok | {error, worker_error()}.
cancel(W, Ref) -> guard(W, {cancel, Ref}).

-doc """
Submit and wait. There is no timeout argument: the worker holds the
request's deadline, `timeout` in its limits.
""".
-spec run(gen_server:server_ref(), term()) -> outcome().
run(W, Request) ->
    case submit(W, Request) of
        {ok, Ref} -> await(W, Ref, infinity);
        {error, _} = Error -> Error
    end.

-doc "`run/2` with `#{source => Source, context => Context}`.".
-spec run(gen_server:server_ref(), binary(), term()) -> outcome().
run(W, Source, Context) -> run(W, #{source => Source, context => Context}).

-doc "The limits a worker starts with, over `wasmtime_limits:untrusted/0`.".
-spec default_limits() -> map().
default_limits() -> maps:merge(wasmtime_limits:untrusted(), ?WORKER_LIMITS).

-doc """
The directories request files go under, by name: `scratch_roots` from the
application environment, or one directory in the user cache that only this
node uses.
""".
-spec roots() -> #{atom() => binary()}.
roots() ->
    case application:get_env(erlang_wasmtime, scratch_roots) of
        {ok, Roots} when is_map(Roots) ->
            #{K => unicode:characters_to_binary(V) || K := V <- Roots};
        _ ->
            Name = lists:concat(["scratch-", node(), "-", os:getpid()]),
            Dir = filename:join(filename:basedir(user_cache, "erlang_wasmtime"), Name),
            #{scratch => unicode:characters_to_binary(Dir)}
    end.

guard(W, Request) ->
    try
        gen_server:call(W, Request, infinity)
    catch
        exit:{noproc, _} -> {error, no_worker()};
        exit:{Reason, _} -> {error, worker_died(Reason)}
    end.

no_worker() -> wasmtime_worker_error:worker(no_worker, ~"worker is gone", #{}).

worker_died(Reason) ->
    wasmtime_worker_error:worker(worker_died, ~"worker died", #{reason => Reason}).

%% --------------------------------------------------------------- callbacks

-spec init({module(), map()}) -> {ok, state()} | {stop, term()}.
init({Adapter, Opts}) ->
    process_flag(trap_exit, true),
    proc_lib:set_label({wasmtime_script_worker, Adapter}),
    Limits = maps:merge(default_limits(), maps:get(limits, Opts, #{})),
    Root = maps:get(root, Opts, scratch),
    maybe
        ok ?= wasmtime_limits:validate(Limits),
        #{Root := Dir} ?= roots(),
        ok ?= filelib:ensure_path(Dir),
        {ok, Artifact} ?= Adapter:artifact(Opts),
        {ok, #state{
            adapter = Adapter,
            artifact = Artifact,
            limits = Limits,
            trusted = trusted(Opts),
            root = Dir
        }}
    else
        {error, {invalid_limits, _} = Bad} -> {stop, Bad};
        {error, #{} = Error} -> {stop, {artifact_failed, Error}};
        {error, Posix} -> {stop, {scratch_root, Posix}};
        Roots when is_map(Roots) -> {stop, {unknown_root, Root, maps:keys(Roots)}}
    end.

trusted(#{trusted := true}) -> true;
trusted(_Opts) -> false.

handle_call({submit, _Request, _Pid}, _From, #state{ref = Ref} = W) when Ref =/= undefined ->
    {reply, {error, wasmtime_worker_error:worker(busy, ~"a request is running", #{})}, W};
handle_call({submit, Request, Pid}, _From, W) ->
    {reply, {ok, Ref}, W1} = start_request(Request, Pid, W),
    {reply, {ok, Ref}, W1};
handle_call({await, Ref, Token}, _From, #state{done_ref = Ref, waiter = undefined} = W) ->
    {reply, {outcome, W#state.done_outcome}, W#state{waiter = {replied, Token}}};
handle_call({await, Ref, Token}, From, #state{ref = Ref, waiter = undefined} = W) ->
    {noreply, W#state{waiter = {From, Token}}};
handle_call({await, Ref, _Token}, _From, #state{ref = R, done_ref = D} = W) when
    Ref =:= R; Ref =:= D
->
    Error = wasmtime_worker_error:worker(already_awaited, ~"another process awaits it", #{}),
    {reply, {error, Error}, W};
handle_call({await, _Ref, _Token}, _From, W) ->
    {reply, {error, unknown_ref()}, W};
handle_call({withdraw, Ref, Token}, _From, #state{done_ref = Ref, waiter = {_, Token}} = W) ->
    {reply, {ok, W#state.done_outcome}, W};
handle_call({withdraw, Ref, Token}, _From, #state{ref = Ref, waiter = {_, Token}} = W) ->
    {reply, still_running, W#state{waiter = undefined}};
handle_call({withdraw, _Ref, _Token}, _From, W) ->
    {reply, {error, unknown_ref()}, W};
handle_call({cancel, Ref}, _From, #state{ref = Ref} = W) ->
    Cancelled = wasmtime_worker_error:worker(cancelled, ~"the request was cancelled", #{}),
    {reply, ok, finish({error, Cancelled}, stop_runner(W))};
handle_call({cancel, _Ref}, _From, W) ->
    {reply, {error, unknown_ref()}, W};
handle_call(_Request, _From, W) ->
    {reply, {error, unknown_call}, W}.

handle_cast({consumed, Ref, Token}, #state{done_ref = Ref, waiter = {_, Token}} = W) ->
    {noreply, W#state{done_ref = undefined, done_outcome = undefined, waiter = undefined}};
handle_cast(_Msg, W) ->
    {noreply, W}.

handle_info({prepared, Ref, AState}, #state{ref = Ref} = W) ->
    {noreply, W#state{astate = {state, AState}}};
handle_info({outcome, Ref, Outcome}, #state{ref = Ref} = W) ->
    {noreply, finish(Outcome, stop_runner(W))};
handle_info({timeout, Timer, deadline}, #state{timer = Timer, limits = Limits} = W) ->
    {noreply, finish({error, timed_out(Limits)}, stop_runner(W))};
handle_info({'DOWN', Mon, process, _, Reason}, #state{rmon = Mon} = W) ->
    %% The runner died without an outcome: a crash in the adapter or a kill.
    Crashed = wasmtime_worker_error:worker(crashed, ~"the request's runner died", #{
        reason => Reason
    }),
    {noreply, finish({error, Crashed}, W#state{runner = undefined, rmon = undefined})};
handle_info({'DOWN', Mon, process, _, _}, #state{smon = Mon, ref = Ref} = W) when
    Ref =/= undefined
->
    %% Whoever submitted is gone: nobody decided the work should go on.
    Cancelled = wasmtime_worker_error:worker(cancelled, ~"the submitter died", #{}),
    {noreply, finish({error, Cancelled}, stop_runner(W))};
handle_info(_Info, W) ->
    {noreply, W}.

terminate(_Reason, #state{ref = undefined}) ->
    ok;
terminate(_Reason, W) ->
    _ = clean(stop_runner(W)),
    ok.

%% ----------------------------------------------------------------- request

unknown_ref() -> wasmtime_worker_error:worker(unknown_ref, ~"no such request", #{}).

timed_out(Limits) ->
    wasmtime_worker_error:worker(timeout, ~"the request ran past its deadline", #{
        timeout => maps:get(timeout, Limits)
    }).

%% An outcome nobody awaited is dropped when the next request comes.
start_request(Request, Pid, W0) ->
    #state{adapter = Adapter, artifact = Artifact, limits = Limits} = W = forget_done(W0),
    Ref = make_ref(),
    Id = binary:encode_hex(crypto:strong_rand_bytes(12), lowercase),
    Dir = filename:join(W#state.root, <<"req-", Id/binary>>),
    {Deadline, Timer} = deadline(maps:get(timeout, Limits)),
    Worker = self(),
    Job = #{
        adapter => Adapter,
        artifact => Artifact,
        request => Request,
        limits => Limits,
        trusted => W#state.trusted,
        dir => Dir,
        deadline => Deadline
    },
    {Runner, RMon} = spawn_opt(fun() -> runner(Worker, Ref, Job) end, runner_options(Limits)),
    {reply, {ok, Ref}, W#state{
        ref = Ref,
        runner = Runner,
        rmon = RMon,
        smon = monitor(process, Pid),
        timer = Timer,
        dir = Dir,
        astate = none
    }}.

forget_done(#state{done_ref = undefined} = W) ->
    W;
forget_done(#state{discarded = N} = W) ->
    W#state{done_ref = undefined, done_outcome = undefined, waiter = undefined, discarded = N + 1}.

%% The runner interrupts the guest at the deadline; the timer is for a
%% runner that did not.
deadline(infinity) ->
    {infinity, undefined};
deadline(Ms) ->
    {
        erlang:monotonic_time(millisecond) + Ms,
        erlang:start_timer(Ms + ?KILL_GRACE, self(), deadline)
    }.

%% The runner is stopped and gone before the request's files are: a kill
%% drops its instance, which interrupts the guest.
stop_runner(#state{runner = undefined} = W) ->
    W;
stop_runner(#state{runner = Runner, rmon = Mon} = W) ->
    exit(Runner, kill),
    receive
        {'DOWN', Mon, process, Runner, _} -> ok
    end,
    W#state{runner = undefined, rmon = undefined}.

%% The request is over: clean, then publish. A late message of the runner
%% is ignored, since `ref` no longer names it.
finish(Outcome, #state{ref = Ref, waiter = Waiter} = W0) ->
    W = clean(W0),
    Waiter1 =
        case Waiter of
            {From, Token} when From =/= replied ->
                gen_server:reply(From, {outcome, Outcome}),
                {replied, Token};
            _ ->
                undefined
        end,
    W#state{ref = undefined, done_ref = Ref, done_outcome = Outcome, waiter = Waiter1}.

clean(#state{adapter = Adapter, astate = AState, dir = Dir, timer = Timer, smon = SMon} = W) ->
    _ = Timer =:= undefined orelse erlang:cancel_timer(Timer, [{async, true}, {info, false}]),
    _ = SMon =:= undefined orelse demonitor(SMon, [flush]),
    case AState of
        {state, State} ->
            try
                Adapter:cleanup(State)
            catch
                Class:Reason ->
                    logger:warning("~p:cleanup/1 failed: ~p:~p", [Adapter, Class, Reason])
            end;
        none ->
            ok
    end,
    _ = Dir =:= undefined orelse file:del_dir_r(Dir),
    W#state{timer = undefined, smon = undefined, dir = undefined, astate = none}.

%% `max_heap_words` bounds the Erlang heap of the process running a request.
runner_options(#{max_heap_words := Words}) ->
    [monitor, {max_heap_size, #{size => Words, kill => true, error_logger => true}}];
runner_options(_) ->
    [monitor].

%% ------------------------------------------------------------------ runner

%% One request, start to finish, in its own process. It only ever sends
%% `prepared` and `outcome`; cleaning is the worker's, which outlives it.
runner(Worker, Ref, Job) ->
    Mon = monitor(process, Worker),
    Outcome =
        try
            execute(Worker, Ref, Job)
        catch
            throw:{outcome, Thrown} -> Thrown
        end,
    receive
        {'DOWN', Mon, process, Worker, _} -> ok
    after 0 -> Worker ! {outcome, Ref, Outcome}
    end.

execute(Worker, Ref, #{adapter := Adapter, artifact := Artifact, request := Request} = Job) ->
    Needs = ok_or_stop(Adapter:requirements(Request, Artifact)),
    ok = admit(Needs, Job),
    Env = environment(Needs, Job),
    {Spec, AState} =
        case Adapter:prepare(Request, Artifact, Env) of
            {ok, S, A} ->
                Worker ! {prepared, Ref, A},
                {S, A};
            {error, Error, A} ->
                Worker ! {prepared, Ref, A},
                refuse(Error)
        end,
    Inst = instantiate(Spec, Job),
    try
        Result = invoke(maps:get(invoke, Spec), Inst, Adapter, AState, Job, []),
        Adapter:decode(Result#{channels => channels(Inst, Spec, Job)}, AState)
    after
        wasmtime:destroy(Inst)
    end.

-spec refuse(term()) -> no_return().
refuse(Error) -> throw({outcome, {error, Error}}).

ok_or_stop({ok, Value}) -> Value;
ok_or_stop({error, Error}) -> refuse(Error).

%% What the request needs against what the worker allows.
admit(Needs, #{limits := Limits, trusted := Trusted}) ->
    Checks = [
        {timeout, maps:get(min_timeout, Needs, 0), min},
        {max_memory_pages, maps:get(min_memory_pages, Needs, 0), min},
        {max_request_bytes, maps:get(request_bytes, Needs, 0), min},
        {max_staged_bytes, maps:get(staged_bytes, Needs, 0), min},
        {max_staged_files, maps:get(staged_files, Needs, 0), min}
    ],
    [
        insufficient(Key, Need, Limit)
     || {Key, Need, min} <- Checks,
        Limit <- [maps:get(Key, Limits, infinity)],
        Limit =/= infinity,
        Need > Limit
    ],
    Writable = [N || N := #{mode := write} <- maps:get(mounts, Needs, #{})],
    _ = Writable =:= [] orelse Trusted orelse insufficient(trusted, Writable, false),
    ok.

-spec insufficient(atom(), term(), term()) -> no_return().
insufficient(Key, Need, Limit) ->
    refuse(
        wasmtime_worker_error:worker(
            insufficient_limit, ~"the request needs more than the worker allows", #{
                limit => Key, needed => Need, allowed => Limit
            }
        )
    ).

%% The mounts, made, and the function that stages a file under one.
environment(Needs, #{dir := Dir, limits := Limits, deadline := Deadline}) ->
    Mounts =
        #{
            Name => M#{host_dir => filename:join(Dir, atom_to_binary(Name))}
         || Name := M <- maps:get(mounts, Needs, #{})
        },
    [ok = filelib:ensure_path(Host) || _ := #{host_dir := Host} <- Mounts],
    put(staged, {0, 0}),
    #{
        mounts => Mounts,
        deadline => Deadline,
        limits => Limits,
        stage => fun(Mount, Path, Bytes) -> stage(Mounts, Limits, Mount, Path, Bytes) end
    }.

stage(Mounts, Limits, Mount, Path, Bytes) ->
    Data = iolist_to_binary(Bytes),
    {Count, Total} = get(staged),
    MaxBytes = maps:get(max_staged_bytes, Limits, infinity),
    MaxFiles = maps:get(max_staged_files, Limits, infinity),
    case {Mounts, safe_path(Path)} of
        {#{Mount := #{host_dir := Host}}, true} when
            Count + 1 =< MaxFiles, Total + byte_size(Data) =< MaxBytes
        ->
            File = filename:join(Host, Path),
            ok = filelib:ensure_dir(File),
            ok = file:write_file(File, Data),
            put(staged, {Count + 1, Total + byte_size(Data)}),
            ok;
        {#{Mount := _}, true} ->
            {error,
                wasmtime_worker_error:worker(
                    insufficient_limit, ~"staging past the worker's bound", #{
                        limit => staged, files => Count + 1, bytes => Total + byte_size(Data)
                    }
                )};
        _ ->
            {error,
                wasmtime_worker_error:worker(
                    bad_stage_path, ~"not a path under a declared mount", #{
                        mount => Mount, path => Path
                    }
                )}
    end.

%% Relative, and every component a plain name: nothing leaves the mount.
safe_path(Path) when is_binary(Path), Path =/= <<>> ->
    filename:pathtype(Path) =:= relative andalso
        lists:all(
            fun(Part) -> Part =/= ~".." andalso Part =/= ~"." andalso Part =/= <<>> end,
            binary:split(Path, ~"/", [global])
        );
safe_path(_) ->
    false.

%% stdout and stderr are the worker's: captured, and bounded.
instantiate(#{module := Module, imports := #{bindings := Bindings}} = Spec, #{limits := Limits}) ->
    Options0 = maps:get(options, Spec, #{}),
    Options1 =
        case Options0 of
            #{wasi := Wasi} ->
                Options0#{
                    wasi := Wasi#{
                        stdout => capture,
                        stderr => capture,
                        output_limit => output_limit(Limits)
                    }
                };
            _ ->
                Options0
        end,
    Options = maps:merge(Options1, maps:with([max_memory_pages, fuel], Limits)),
    %% the request's host calls, its start section's included
    {Counted, _} = wasmtime_host_budget:wrap(
        Bindings, maps:get(max_host_calls, Limits, undefined)
    ),
    case wasmtime:instantiate(Module, Counted, Options) of
        {ok, Inst} -> Inst;
        {error, Error} -> refuse(wasmtime_worker_error:runtime(Error))
    end.

output_limit(#{max_output_bytes := #{stdout := Out, stderr := Err}}) -> max(Out, Err);
output_limit(#{max_output_bytes := N}) -> N.

%% Each call on the time the request has left. The adapter says what a
%% result means; a timeout is the worker's to name.
invoke([], _Inst, _Adapter, _AState, _Job, Values) ->
    result(returned, Values, undefined, undefined);
invoke([{call, Name, Args} | Rest], Inst, Adapter, AState, #{deadline := Deadline} = Job, _Values) ->
    Result = wasmtime:call(Inst, Name, Args, call_options(Deadline, Job)),
    case {Result, Adapter:classify(Result, AState)} of
        {{error, #{kind := timeout}}, _} ->
            refuse(timed_out(maps:get(limits, Job)));
        {{ok, Values}, continue} ->
            invoke(Rest, Inst, Adapter, AState, Job, Values);
        {{error, _}, continue} ->
            invoke(Rest, Inst, Adapter, AState, Job, []);
        {{ok, Values}, {stop, returned}} ->
            result(returned, Values, undefined, undefined);
        {{error, Error}, {stop, {exited, Code}}} ->
            result(exited, [], Code, Error);
        {{error, Error}, {stop, _}} ->
            result(trapped, [], undefined, Error);
        {{ok, _}, {stop, {exited, Code}}} ->
            result(exited, [], Code, undefined);
        {{ok, _}, {stop, trapped}} ->
            result(trapped, [], undefined, undefined)
    end.

result(Outcome, Values, Exit, Error) ->
    #{outcome => Outcome, values => Values, exit => Exit, error => Error}.

call_options(infinity, _Job) ->
    #{};
call_options(Deadline, #{limits := Limits}) ->
    case Deadline - erlang:monotonic_time(millisecond) of
        Left when Left > 0 -> #{timeout => Left};
        _ -> refuse(timed_out(Limits))
    end.

%% What the guest wrote. Output past the bound was dropped by the capture,
%% and a request that lost output does not get a partial answer.
channels(Inst, #{options := #{wasi := _}}, #{limits := Limits}) ->
    case wasmtime:read_output(Inst) of
        {ok, {Out, Err, {0, 0}}} ->
            #{stdout => Out, stderr => Err};
        {ok, {_, _, {DroppedOut, DroppedErr}}} ->
            refuse(
                wasmtime_worker_error:worker(
                    output_limit, ~"the guest wrote past the output bound", #{
                        limit => maps:get(max_output_bytes, Limits),
                        dropped => #{stdout => DroppedOut, stderr => DroppedErr}
                    }
                )
            )
    end;
channels(_Inst, _Spec, _Job) ->
    #{stdout => <<>>, stderr => <<>>}.
