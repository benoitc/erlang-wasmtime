-module(wasmtime_worker_error).
-moduledoc """
The errors the script worker answers with: erlang_wasm's
`wasm_worker_error`.

`class` says which layer decided the request had failed: `worker` is the
kernel, `adapter` the adapter, and `runtime` means `wasmtime` returned an
error nobody reinterpreted; it is in `ctx.error`. The set of kinds is
closed: an adapter with more to say puts a binary code in `ctx`.
""".

-export([worker/3, adapter/3, runtime/1, runtime/2]).
-export([kinds/0, is_error/1, class_of/1, kind_of/1]).

-export_type([class/0, kind/0, worker_error/0]).

-type class() :: worker | adapter | runtime.

-type kind() ::
    timeout
    | cancelled
    | output_limit
    | crashed
    | insufficient_limit
    | bad_stage_path
    | busy
    | still_running
    | already_awaited
    | unknown_ref
    | no_worker
    | worker_died
    | exit
    | adapter_failure
    | runtime_failure.

-type worker_error() :: #{class := class(), kind := kind(), msg := binary(), ctx := map()}.

-doc "An error the kernel itself decided on.".
-spec worker(kind(), binary(), map()) -> worker_error().
worker(Kind, Message, Ctx) ->
    #{class => worker, kind => Kind, msg => Message, ctx => Ctx}.

-doc "An error the adapter diagnosed: `exit` or `adapter_failure`, the detail in `ctx`.".
-spec adapter(exit | adapter_failure, binary(), map()) -> worker_error().
adapter(Kind, Message, Ctx) when Kind =:= exit; Kind =:= adapter_failure ->
    #{class => adapter, kind => Kind, msg => Message, ctx => Ctx}.

-doc "Wrap an error of `wasmtime` without reinterpreting it: it stays in `ctx.error`.".
-spec runtime(map()) -> worker_error().
runtime(Error) -> runtime(Error, #{}).

-spec runtime(map(), map()) -> worker_error().
runtime(Error, Ctx) ->
    Message =
        case Error of
            #{msg := M} when is_binary(M) -> M;
            _ -> ~"runtime error"
        end,
    #{class => runtime, kind => runtime_failure, msg => Message, ctx => Ctx#{error => Error}}.

-doc "Every kind this module can produce.".
-spec kinds() -> [kind()].
kinds() ->
    [
        timeout,
        cancelled,
        output_limit,
        crashed,
        insufficient_limit,
        bad_stage_path,
        busy,
        still_running,
        already_awaited,
        unknown_ref,
        no_worker,
        worker_died,
        exit,
        adapter_failure,
        runtime_failure
    ].

-doc "Whether a term is a well-formed worker error.".
-spec is_error(term()) -> boolean().
is_error(#{class := Class, kind := Kind, msg := Message, ctx := Ctx}) when
    is_binary(Message), is_map(Ctx)
->
    lists:member(Kind, kinds()) andalso class_allows(Class, Kind);
is_error(_) ->
    false.

class_allows(adapter, Kind) -> Kind =:= exit orelse Kind =:= adapter_failure;
class_allows(runtime, Kind) -> Kind =:= runtime_failure;
class_allows(worker, Kind) -> not lists:member(Kind, [exit, adapter_failure, runtime_failure]);
class_allows(_, _) -> false.

-spec class_of(worker_error()) -> class().
class_of(#{class := Class}) -> Class.

-spec kind_of(worker_error()) -> kind().
kind_of(#{kind := Kind}) -> Kind.
