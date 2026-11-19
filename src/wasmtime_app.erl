-module(wasmtime_app).
-moduledoc false.
-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) -> wasmtime_sup:start_link().

stop(_State) -> ok.
