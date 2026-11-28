-module(wasmtime_wasi_preview1).
-moduledoc """
WASI preview 1, with the functions of erlang_wasm's `wasi_preview1` that have
a meaning on Wasmtime.
""".

-export([imports/1, exit_code/1]).

-doc #{equiv => wasmtime_wasi:imports(Config)}.
-spec imports(map()) -> map().
imports(Config) -> wasmtime_wasi:imports(Config).

-doc "The exit status in the error `proc_exit` produces, or `error`.".
-spec exit_code(term()) -> {ok, integer()} | error.
exit_code(#{class := trap, ctx := #{wasi_exit := Code}}) -> {ok, Code};
exit_code(_) -> error.
