-module(wasmtime_sup).
-moduledoc false.
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% The module cache is the only process: instances have their own OS thread
%% and no Erlang process, so nothing else needs supervising.
init([]) ->
    Cache = #{id => wasmtime_module_cache, start => {wasmtime_module_cache, start_link, []}},
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Cache]}}.
