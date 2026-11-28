-module(wasmtime_actor_registry).
-moduledoc false.
%% Where wasmtime_actor:send/2 finds an actor's queue, and who forgets an
%% actor that died. Each actor writes its own row when it starts and deletes
%% it when it stops; an actor killed outright runs no cleanup, so this
%% process monitors every one. The table belongs to the supervisor, so a
%% restart here loses nothing.
-behaviour(gen_server).

-export([start_link/0, new_table/0, watch/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(TAB, wasmtime_actors).

%% the monitors are the whole state
-record(state, {}).

-type state() :: #state{}.

-spec start_link() -> {ok, pid()}.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec new_table() -> ok.
new_table() ->
    ?TAB = ets:new(?TAB, [
        named_table, set, public, {read_concurrency, true}, {write_concurrency, true}
    ]),
    ok.

-spec watch(pid()) -> ok.
watch(Pid) -> gen_server:cast(?MODULE, {watch, Pid}).

%% An actor writes its row before it asks to be watched, and a restarted
%% registry registers its name before this scan, so a request lost with the
%% old registry is for a row the scan finds.
-spec init([]) -> {ok, state()}.
init([]) ->
    Live = ets:select(?TAB, [{{'$1', '_', '_', '_'}, [], ['$1']}]),
    _ = [monitor(process, Pid) || Pid <- Live],
    {ok, #state{}}.

handle_call(_Request, _From, State) -> {reply, {error, unknown_call}, State}.

handle_cast({watch, Pid}, State) ->
    _ = monitor(process, Pid),
    {noreply, State};
handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', _Ref, process, Pid, _Why}, State) ->
    true = ets:delete(?TAB, Pid),
    {noreply, State};
handle_info(_Message, State) ->
    {noreply, State}.
