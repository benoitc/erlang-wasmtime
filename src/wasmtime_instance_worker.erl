-module(wasmtime_instance_worker).
-moduledoc """
A worker owning one WebAssembly instance: erlang_wasm's
`wasm_instance_worker`, for this runtime.

Use it when a module you did not write handles requests: one instance in
one process, one request at a time, a deadline on each, and by default a
fresh instance for every request.

```erlang
{ok, Mod} = wasmtime:load_file("plugin.wasm"),
{ok, W} = wasmtime_instance_worker:start_link(Mod, #{limits => wasmtime_limits:untrusted()}),
{ok, [3]} = wasmtime_instance_worker:call(W, ~"add", [1, 2]).
```

## Isolation policy

- `fresh` (the default) destroys and re-creates the instance after every
  request, so no memory, global or table content survives it.
- `reuse` keeps the instance: faster, and state persists. Correct only for
  modules that are stateless by construction, or that you trust.

## Deadlines

The worker runs each request with the time it has left as the call's
`timeout`: the guest is interrupted on its own thread and the worker lives
on. erlang_wasm kills its worker instead, because its guest runs inside the
worker process. The caller waits a little longer than the deadline and
kills the worker only if it has not answered by then, which happens when a
host function of yours is what hangs.

Host functions run in the worker process.

## Parallelism

Comes from more workers, never from concurrent calls into one instance. Run
a pool and check one out per request.

## Naming a worker

The `name` option is a label: `info/1` gives it back and it is the process
label that `observer` and crash dumps show. The process is not registered
under it.
""".

-behaviour(gen_server).

-export([start_link/1, start_link/2, call/3, call/4, stop/1, info/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2, terminate/2]).

%% A default, not a policy: `worker_timeout` in the application environment
%% changes it, and a deadline that belongs to a request goes in call/4.
-define(DEFAULT_TIMEOUT, 5000).
%% How long the caller waits past the deadline before it kills the worker.
%% The worker interrupts the guest at the deadline itself; this only covers
%% a worker stuck in one of its own host functions.
-define(KILL_GRACE, 1000).

-record(state, {
    module :: wasmtime:module_ref(),
    imports = #{} :: map(),
    %% instantiate options: `options` with `limits` on top
    options = #{} :: map(),
    isolation = fresh :: fresh | reuse,
    instance :: wasmtime:instance() | undefined,
    served = 0 :: non_neg_integer(),
    name :: term()
}).

-type state() :: #state{}.

-doc """
Start a worker over a module.

`Opts` accepts `imports`, `limits`, `isolation` (`fresh` | `reuse`) and
`name`, as erlang_wasm's worker does, and `options`: other
`wasmtime:instantiate/3` options, such as `wasi`. `limits` is a nested map
of the keys `wasmtime_limits` lists. The module's start section runs when
the worker instantiates it; a failure there stops the worker.
""".
-spec start_link(wasmtime:module_ref()) -> {ok, pid()} | {error, term()}.
start_link(Module) -> start_link(Module, #{}).

-spec start_link(wasmtime:module_ref(), map()) -> {ok, pid()} | {error, term()}.
start_link(Module, Opts) when is_map(Opts) ->
    gen_server:start_link(?MODULE, {Module, Opts}, []).

-doc """
Run one request, with `worker_timeout` as its deadline: five seconds unless
you set it.

```erlang
application:set_env(erlang_wasmtime, worker_timeout, 30000).
```
""".
-spec call(pid(), iodata(), [term()]) -> {ok, [term()] | term()} | wasmtime:error().
call(Pid, Function, Args) ->
    call(
        Pid, Function, Args, application:get_env(erlang_wasmtime, worker_timeout, ?DEFAULT_TIMEOUT)
    ).

-doc """
Run one request with its own deadline, in milliseconds or `infinity`.

The deadline covers the wait for the worker as well as the call. When it
passes, the guest is interrupted and the answer is `kind => timeout`. A
worker that is gone answers `kind => no_worker`; one that dies during the
request, `kind => worker_died`.
""".
-spec call(pid(), iodata(), [term()], timeout()) -> {ok, [term()] | term()} | wasmtime:error().
call(Pid, Function, Args, infinity) ->
    run(Pid, {run, Function, Args, infinity}, infinity);
call(Pid, Function, Args, Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    run(Pid, {run, Function, Args, Deadline}, Timeout + ?KILL_GRACE).

run(Pid, Request, Wait) ->
    try
        gen_server:call(Pid, Request, Wait)
    catch
        exit:{timeout, _} ->
            exit(Pid, kill),
            timed_out();
        exit:{noproc, _} ->
            refused(link, no_worker, ~"worker is gone");
        exit:{Reason, _} ->
            refused(
                trap, worker_died, iolist_to_binary(io_lib:format("worker died: ~0p", [Reason]))
            )
    end.

-spec stop(pid()) -> ok.
stop(Pid) -> gen_server:stop(Pid).

-doc "What the worker is: `served`, `isolation` and `name`.".
-spec info(pid()) -> {ok, map()}.
info(Pid) -> gen_server:call(Pid, info).

timed_out() -> refused(trap, timeout, ~"request timed out").

refused(Class, Kind, Message) ->
    {error, #{class => Class, kind => Kind, message => Message}}.

%% --------------------------------------------------------------- callbacks

-spec init({wasmtime:module_ref(), map()}) -> {ok, state(), {continue, instantiate}}.
init({Module, Opts}) ->
    %% Exits are trapped so terminate/2 runs on a supervisor shutdown and the
    %% instance's thread and memory go when the worker is asked to stop.
    process_flag(trap_exit, true),
    Name = maps:get(name, Opts, undefined),
    proc_lib:set_label({wasmtime_instance_worker, Name}),
    State = #state{
        module = Module,
        imports = maps:get(imports, Opts, #{}),
        options = maps:merge(maps:get(options, Opts, #{}), maps:get(limits, Opts, #{})),
        isolation = maps:get(isolation, Opts, fresh),
        name = Name
    },
    %% In handle_continue, so a large module does not block the supervisor.
    {ok, State, {continue, instantiate}}.

handle_continue(instantiate, State) ->
    case new_instance(State) of
        {ok, Inst} -> {noreply, State#state{instance = Inst}};
        {error, Reason} -> {stop, {instantiate_failed, Reason}, State}
    end.

handle_call({run, _Function, _Args, _Deadline}, _From, #state{instance = undefined} = State) ->
    {reply, refused(link, no_instance, ~"worker has no instance"), State};
handle_call({run, Function, Args, Deadline}, _From, #state{instance = Inst} = State) ->
    case remaining(Deadline) of
        0 ->
            %% It waited behind other requests past its own deadline.
            {reply, timed_out(), State};
        Left ->
            Result = wasmtime:call(Inst, Function, Args, call_options(Left)),
            {reply, Result, recycle(State#state{served = State#state.served + 1})}
    end;
handle_call(info, _From, #state{served = Served, isolation = Isolation, name = Name} = State) ->
    {reply, {ok, #{served => Served, isolation => Isolation, name => Name}}, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, #state{instance = undefined}) -> ok;
terminate(_Reason, #state{instance = Inst}) -> wasmtime:destroy(Inst).

%% ----------------------------------------------------------------- helpers

remaining(infinity) -> infinity;
remaining(Deadline) -> max(Deadline - erlang:monotonic_time(millisecond), 0).

%% Without a deadline the instance's own `timeout` limit, if any, applies.
call_options(infinity) -> #{};
call_options(Left) -> #{timeout => Left}.

new_instance(#state{module = Module, imports = Imports, options = Options}) ->
    wasmtime:instantiate(Module, Imports, Options).

%% Under `fresh` the instance is replaced after every request, so nothing
%% carries over: not linear memory, not globals, not table contents.
recycle(#state{isolation = reuse} = State) ->
    State;
recycle(#state{isolation = fresh, instance = Old} = State) ->
    ok = wasmtime:destroy(Old),
    case new_instance(State) of
        {ok, Inst} -> State#state{instance = Inst};
        %% Alive without an instance: the next request gets a clear error
        %% instead of a crash loop, and a supervisor can decide.
        {error, _} -> State#state{instance = undefined}
    end.
