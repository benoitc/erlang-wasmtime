-module(wasmtime_limits).
-moduledoc """
Resource limits for an instance, with erlang_wasm's `wasm_limits` functions.

Pass a limits map to `wasmtime:instantiate/3`. The keys go flat into the
options map, beside the other options:

```erlang
Opts = wasmtime_limits:merge(wasmtime_limits:untrusted(), #{host_timeout => 1000}),
{ok, Inst} = wasmtime:instantiate(Mod, Imports, Opts).
```

| Limit | Bounds |
| --- | --- |
| `timeout` | wall clock per call, in milliseconds; the default of every call on the instance |
| `fuel` | execution budget per call; the module must be compiled with `fuel => true` |
| `max_memory_pages` | linear memory, in 64 KB pages |

A `timeout` or `fuel` given to `call/4` wins over the instance's.
`max_memory_pages` is the same cap as `memory_limit`, which wins when both
are given.

erlang_wasm's `max_depth`, `max_heap_words` and `max_host_calls` are refused
with `kind => invalid_limits`: the guest runs on its own thread with
Wasmtime's stack limit, holds no Erlang heap, and host calls are bounded in
time by `host_timeout`, not counted.

The presets hold no `fuel`, since a module compiled without it refuses the
option. Add it yourself for a metered module.
""".

-export([untrusted/0, trusted/0, default/0, merge/2, validate/1]).

-export_type([limits/0]).

-type limits() :: #{
    timeout => timeout(),
    fuel => pos_integer() | infinity,
    max_memory_pages => non_neg_integer() | infinity
}.

-doc "Limits for a module you did not write: one second per call, 16 MB of memory.".
-spec untrusted() -> limits().
untrusted() ->
    #{timeout => 1_000, max_memory_pages => 256}.

-doc """
Limits for your own code: no timeout. Faults still come back as values, and
the default 256 MB memory cap still applies.
""".
-spec trusted() -> limits().
trusted() ->
    #{timeout => infinity}.

-doc #{equiv => untrusted()}.
-spec default() -> limits().
default() -> untrusted().

-doc "Limits from `Base` with those of `Override` on top.".
-spec merge(map(), map()) -> map().
merge(Base, Override) -> maps:merge(Base, Override).

-doc """
Check the limits in a map and reject one that cannot mean what it says, or
that this runtime does not enforce. Other keys are not looked at.
""".
-spec validate(map()) -> ok | {error, {invalid_limits, [atom()]}}.
validate(Limits) when is_map(Limits) ->
    Budget = fun(V) -> V =:= infinity orelse (is_integer(V) andalso V > 0) end,
    Pages = fun(V) -> V =:= infinity orelse (is_integer(V) andalso V >= 0) end,
    Refused = fun(_) -> false end,
    Checks = [
        {timeout, Budget},
        {fuel, Budget},
        {max_memory_pages, Pages},
        {max_depth, Refused},
        {max_heap_words, Refused},
        {max_host_calls, Refused}
    ],
    case [K || {K, Pred} <- Checks, maps:is_key(K, Limits), not Pred(maps:get(K, Limits))] of
        [] -> ok;
        Bad -> {error, {invalid_limits, Bad}}
    end.
