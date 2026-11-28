-module(wasmtime_sup).
-moduledoc false.
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% The module cache and the actor registry are the only processes: instances
%% have their own OS thread and no Erlang process. The actor table is made
%% here so it outlives the registry.
init([]) ->
    ok = wasmtime_actor_registry:new_table(),
    Children = [
        #{id => Module, start => {Module, start_link, []}}
     || Module <- [wasmtime_module_cache, wasmtime_actor_registry]
    ],
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.
