-module(wasmtime_wasi_preview3).
-moduledoc """
Run a WASI 0.3 component: erlang_wasm's `wasi_preview3:run_command` and
`run_serve`.

Wasmtime links WASI 0.2 and 0.3 beside each other, so this is
`wasmtime_wasi_preview2` under erlang_wasm's other name. A 0.3 component needs
a library with WASI 0.3 (`wasmtime:features/0`, `wasi_p3`).
""".

-export([run_command/3, run_serve/3]).

-doc #{equiv => wasmtime_wasi_preview2:run_command(Component, Stdin, Options)}.
-spec run_command(
    binary() | wasmtime_component:prepared(),
    binary(),
    wasmtime_wasi_preview2:command_options()
) -> wasmtime_wasi_preview2:command_result().
run_command(Component, Stdin, Options) ->
    wasmtime_wasi_preview2:run_command(Component, Stdin, Options).

-doc #{equiv => wasmtime_wasi_preview2:run_serve(Component, Request, Options)}.
-spec run_serve(
    binary() | wasmtime_component:prepared(),
    wasmtime_wasi_preview2:serve_request(),
    wasmtime_wasi_preview2:command_options()
) -> wasmtime_wasi_preview2:serve_result().
run_serve(Component, Request, Options) ->
    wasmtime_wasi_preview2:run_serve(Component, Request, Options).
