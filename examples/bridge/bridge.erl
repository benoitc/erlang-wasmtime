%% A gen_server that owns one instance of counter.wat and bridges it to the
%% VM: an ETS table for state, logger for output, and plain messages to
%% subscribed processes.
%%
%%   1> c("examples/bridge/bridge.erl").
%%   2> {ok, _} = bridge:start_link("examples/bridge/counter.wat").
%%   3> bridge:subscribe().
%%   4> bridge:bump(5).
%%   5
%%   5> bridge:bump(2).
%%   7
%%   6> flush().
%%   Shell got {bridge,<<"hits">>,5}
%%   Shell got {bridge,<<"hits">>,7}
%%   7> bridge:upcase(<<"hello from erlang">>).
%%   <<"HELLO FROM ERLANG">>
-module(bridge).
-behaviour(gen_server).

-export([start_link/1, bump/1, upcase/1, subscribe/0]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(SCRATCH, 1024).

start_link(WatFile) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, WatFile, []).

bump(By) -> gen_server:call(?MODULE, {bump, By}).
upcase(Bin) -> gen_server:call(?MODULE, {upcase, Bin}).
subscribe() -> gen_server:call(?MODULE, {subscribe, self()}).

init(WatFile) ->
    Kv = ets:new(bridge_kv, [set]),
    {ok, Wat} = file:read_file(WatFile),
    {ok, Mod} = wasmtime:compile({wat, Wat}),
    Self = self(),
    Imports = #{
        %% log(ptr, len): a guest string goes to the Erlang logger
        {~"erlang", ~"log"} => fun(Ctx, [Ptr, Len]) ->
            {ok, Msg} = wasmtime:read_memory(Ctx, Ptr, Len),
            logger:notice("guest: ~s", [Msg]),
            {ok, []}
        end,
        %% kv_get(kptr, klen) -> i32: read from ETS, 0 when absent
        {~"erlang", ~"kv_get"} => fun(Ctx, [Ptr, Len]) ->
            {ok, Key} = wasmtime:read_memory(Ctx, Ptr, Len),
            case ets:lookup(Kv, Key) of
                [{_, V}] -> {ok, [V]};
                [] -> {ok, [0]}
            end
        end,
        %% kv_put(kptr, klen, value): write to ETS
        {~"erlang", ~"kv_put"} => fun(Ctx, [Ptr, Len, V]) ->
            {ok, Key} = wasmtime:read_memory(Ctx, Ptr, Len),
            true = ets:insert(Kv, {Key, V}),
            {ok, []}
        end,
        %% notify(kptr, klen, value): fan out to subscribers. The host fun runs
        %% inside this gen_server, so it asks the server (itself) to do it
        %% after the call returns rather than touching state directly.
        {~"erlang", ~"notify"} => fun(Ctx, [Ptr, Len, V]) ->
            {ok, Key} = wasmtime:read_memory(Ctx, Ptr, Len),
            gen_server:cast(Self, {notify, Key, V}),
            {ok, []}
        end
    },
    {ok, Inst} = wasmtime:instantiate(Mod, #{imports => Imports, memory_limit => 1024 * 1024}),
    {ok, #{inst => Inst, kv => Kv, subs => []}}.

handle_call({bump, By}, _From, #{inst := Inst} = S) ->
    {ok, [N]} = wasmtime:call(Inst, ~"bump", [By], #{timeout => 1000}),
    {reply, N, S};
handle_call({upcase, Bin}, _From, #{inst := Inst} = S) ->
    %% write the argument into guest memory, let the guest work in place,
    %% read it back
    ok = wasmtime:write_memory(Inst, ?SCRATCH, Bin),
    {ok, []} = wasmtime:call(Inst, ~"upcase", [?SCRATCH, byte_size(Bin)]),
    {ok, Out} = wasmtime:read_memory(Inst, ?SCRATCH, byte_size(Bin)),
    {reply, Out, S};
handle_call({subscribe, Pid}, _From, #{subs := Subs} = S) ->
    {reply, ok, S#{subs => [Pid | Subs]}}.

handle_cast({notify, Key, V}, #{subs := Subs} = S) ->
    [Pid ! {bridge, Key, V} || Pid <- Subs],
    {noreply, S}.
