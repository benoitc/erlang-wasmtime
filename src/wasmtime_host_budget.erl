-module(wasmtime_host_budget).
-moduledoc false.
%% `max_host_calls`, for the workers: the host functions of an import map
%% counted, and refused past the limit until the count is reset.

-export([wrap/2, reset/1]).

-export_type([budget/0]).

-type budget() :: none | {atomics:atomics_ref(), non_neg_integer()}.

-spec wrap(map(), non_neg_integer() | infinity | undefined) -> {map(), budget()}.
wrap(Imports, Max) when is_integer(Max) ->
    Budget = {atomics:new(1, [{signed, false}]), Max},
    {#{Key => counted(Fun, Budget) || Key := Fun <- Imports}, Budget};
wrap(Imports, _) ->
    {Imports, none}.

-spec reset(budget()) -> ok.
reset(none) -> ok;
reset({Count, _}) -> atomics:put(Count, 1, 0).

counted({wasm_func, Fun, Type}, Budget) ->
    {wasm_func, counted(Fun, Budget), Type};
counted(Fun, Budget) when is_function(Fun, 1) ->
    fun(Args) ->
        ok = charge(Budget),
        Fun(Args)
    end;
counted(Fun, Budget) when is_function(Fun, 2) ->
    fun(Context, Args) ->
        ok = charge(Budget),
        Fun(Context, Args)
    end;
counted({Module, Function}, Budget) when is_atom(Module), is_atom(Function) ->
    counted(fun Module:Function/2, Budget);
%% not callable: instantiate says so
counted(Other, _) ->
    Other.

charge({Count, Max}) ->
    case atomics:add_get(Count, 1, 1) of
        Calls when Calls > Max ->
            wasmtime_error:exhaustion(host_call_limit, #{limit => Max, calls => Calls});
        _ ->
            ok
    end.
