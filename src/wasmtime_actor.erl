-module(wasmtime_actor).
-moduledoc """
A WebAssembly component that handles typed messages, one at a time, as an OTP
process: erlang_wasm's `wasm_actor`. [Actors](actors.md) is the guide.

An actor owns one component instance for its whole life, so the guest keeps
its state from one message to the next. It takes messages from Erlang through
`send/2` and from its own guest, which posts them to a destination you wire
when you start it. It is a `gen_server`, so you put it under your own
supervisor. The `erlang_wasmtime` application must be running.

A guest that traps stops the actor with `{handle_failed, Error}`.
""".

-behaviour(gen_server).

-export([start_link/2, send/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-export_type([dest/0, to/0, opts/0, type/0]).

-doc """
A message type, spelled as erlang_wasm's: `u8` to `u64`, `s8` to `s64`,
`f32`, `f64`, `bool`, `char`, `string`, `{list, T}`, `{option, T}`,
`{tuple, [T]}`, `{record, [{Name, T}]}`, `{variant, [{Case, T | none}]}`,
`{result, T | none, T | none}`, `{enum, [Name]}` or `{flags, [Name]}`.
""".
-type type() :: atom() | {atom(), term()} | {atom(), term(), term()}.

-define(TAB, wasmtime_actors).
-define(TAG, '$wasmtime_actor').
-define(DEFAULT_CAPACITY, 1024).
-define(SEND_ERROR, {enum, [~"full", ~"closed"]}).
-define(POST, {~"$root", ~"post"}).
-define(HANDLE, ~"handle").

-type dest() :: pid() | atom().
-type to() ::
    dest()
    | self
    | fun((term()) -> ok | {error, full | closed}).
-type opts() :: #{
    message := type(),
    to => to(),
    capacity => pos_integer(),
    register => atom(),
    imports => #{{binary(), binary()} => function()},
    limits => map()
}.

-record(state, {instance, message, counter}).

-type state() :: #state{}.

%%% ------------------------------------------------------------------ api ---

-doc """
Start an actor over a component, linked to the caller.

`Component` is the component's bytes, or what `wasmtime_component:prepare/1`
made of them. `Opts`:

- `message` (required): the message type, `t:type/0`. Values only: no
  resources, futures or streams.
- `to`: where the guest's `post` goes: an actor's pid or registered name,
  `self`, or a `fun(Msg)` answering `ok` or `{error, full | closed}`. Left
  out, every post answers `closed`.
- `capacity`: how many messages the queue holds, 1024 when left out.
- `register`: a local name for the actor, registered once its queue exists.
- `imports`: more host functions for the guest. `post` is the actor's own.
- `limits`: instance limits, as `wasmtime:instantiate/3` takes them.

The instance is made before this returns, so a component that does not
instantiate, or has no `handle` export, is an `{error, Reason}` here.
""".
-spec start_link(binary() | wasmtime_component:prepared(), opts()) ->
    {ok, pid()} | {error, term()}.
start_link(Component, Opts) ->
    gen_server:start_link(?MODULE, {Component, Opts}, []).

-doc """
Queue `Msg` for the actor at `Dest`, a pid or a registered name.

Answers `ok` once the message is in the queue, `{error, full}` when the queue
is at its capacity and `{error, closed}` when no actor is there. It never
waits for the actor. Raises `badarg` when `Msg` does not fit the message type.
""".
-spec send(dest(), term()) -> ok | {error, full | closed}.
send(Dest, Msg) ->
    case lookup(Dest) of
        {ok, Pid, Counter, Capacity, Type} ->
            wasmtime_actor_type:fits(Type, Msg) orelse error(badarg, [Dest, Msg]),
            admit(Pid, Counter, Capacity, Msg);
        closed ->
            {error, closed}
    end.

%%% ------------------------------------------------------------ callbacks ---

-spec init({binary() | wasmtime_component:prepared(), opts()}) ->
    {ok, state()} | {error, term()}.
init({Component, Opts}) ->
    %% Exits are trapped so `terminate/2' runs on a supervisor's shutdown and
    %% the instance is destroyed then, not whenever the process is collected.
    process_flag(trap_exit, true),
    proc_lib:set_label({?MODULE, maps:get(register, Opts, undefined)}),
    case setup(Component, Opts) of
        {ok, State} -> {ok, State};
        {error, Reason} -> {error, Reason}
    end.

handle_call(_Req, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(
    {?TAG, Msg},
    #state{
        instance = Inst,
        message = Type,
        counter = Counter
    } = State
) ->
    %% Out of the queue: its slot is free before the guest runs, so a post
    %% from this handler to this actor finds room for one more.
    _ = atomics:sub(Counter, 1, 1),
    case wasmtime_component:call(Inst, ?HANDLE, {[Type], none}, [Msg]) of
        {ok, _} -> {noreply, State};
        {error, Error} -> {stop, {handle_failed, Error}, State}
    end;
handle_info(_Info, State) ->
    {noreply, State}.

%% The row goes first, so a send from now on answers `closed', then the
%% instance and its memory.
terminate(_Reason, #state{instance = Inst}) ->
    true = ets:delete(?TAB, self()),
    wasmtime_component:destroy(Inst).

%%% -------------------------------------------------------------- helpers ---

setup(Component, #{message := Type} = Opts) ->
    Capacity = maps:get(capacity, Opts, ?DEFAULT_CAPACITY),
    case is_integer(Capacity) andalso Capacity >= 1 of
        false ->
            {error, {bad_capacity, Capacity}};
        true ->
            case wasmtime_actor_type:plain(Type) of
                true -> start(Component, Opts, Type, Capacity, maps:get(to, Opts, undefined));
                false -> {error, {bad_message_type, Type}}
            end
    end;
setup(_Component, _Opts) ->
    {error, no_message_type}.

start(Component, Opts, Type, Capacity, To) ->
    Name = maps:get(register, Opts, undefined),
    case ets:whereis(?TAB) of
        undefined -> {error, not_started};
        _ when not is_atom(Name) -> {error, {bad_name, Name}};
        _ -> free_name(Name, Component, Opts, Type, Capacity, To)
    end.

%% A name already taken is refused before any instance is built for it.
free_name(Name, Component, Opts, Type, Capacity, To) ->
    case Name =/= undefined andalso whereis(Name) of
        Pid when is_pid(Pid) ->
            {error, {already_started, Pid}};
        _ ->
            Imports = (maps:get(imports, Opts, #{}))#{?POST => post(To, Type)},
            Limits = maps:get(limits, Opts, #{}),
            case wasmtime_component:instantiate(Component, Imports, Limits) of
                {ok, Inst} -> ready(Inst, Type, Capacity, Name);
                {error, _} = E -> E
            end
    end.

ready(Inst, Type, Capacity, Name) ->
    case lists:member(?HANDLE, wasmtime_component:exports(Inst)) of
        true ->
            Counter = atomics:new(1, [{signed, true}]),
            true = ets:insert(?TAB, {self(), Counter, Capacity, Type}),
            ok = wasmtime_actor_registry:watch(self()),
            State = #state{instance = Inst, message = Type, counter = Counter},
            case named(Name) of
                ok ->
                    {ok, State};
                {error, _} = E ->
                    terminate(normal, State),
                    E
            end;
        false ->
            ok = wasmtime_component:destroy(Inst),
            {error, no_handle_export}
    end.

%% The name is registered last, not by `gen_server' before `init/1': a
%% sender that finds the name then finds the queue too, so a restarted actor
%% is never `closed' to someone who just looked it up.
named(undefined) ->
    ok;
named(Name) ->
    try register(Name, self()) of
        true -> ok
    catch
        error:badarg -> {error, {already_started, whereis(Name)}}
    end.

%% The guest's `post', which runs in this process while `handle' runs.
post(To, Type) ->
    wasmtime_component:import_fun(
        {[Type], {result, none, ?SEND_ERROR}},
        fun([Msg]) ->
            case deliver(To, Msg) of
                ok -> {ok, undefined};
                {error, full} -> {error, ~"full"};
                {error, closed} -> {error, ~"closed"}
            end
        end
    ).

deliver(undefined, _Msg) -> {error, closed};
deliver(self, Msg) -> send(self(), Msg);
deliver(Fun, Msg) when is_function(Fun, 1) -> Fun(Msg);
deliver(Dest, Msg) -> send(Dest, Msg).

lookup(Name) when is_atom(Name) ->
    case whereis(Name) of
        undefined -> closed;
        Pid -> lookup(Pid)
    end;
lookup(Pid) when is_pid(Pid) ->
    %% No table means the application is not started, so no actor anywhere.
    try ets:lookup(?TAB, Pid) of
        [{Pid, Counter, Capacity, Type}] -> {ok, Pid, Counter, Capacity, Type};
        [] -> closed
    catch
        error:badarg -> closed
    end;
lookup(_Other) ->
    closed.

%% The counter goes up before the check, so senders racing for the last slot
%% cannot both take it: each one past the capacity gives its increment back.
admit(Pid, Counter, Capacity, Msg) ->
    case atomics:add_get(Counter, 1, 1) of
        N when N > Capacity ->
            _ = atomics:sub(Counter, 1, 1),
            {error, full};
        _ ->
            Pid ! {?TAG, Msg},
            ok
    end.
