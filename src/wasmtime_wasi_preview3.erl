-module(wasmtime_wasi_preview3).
-moduledoc """
Run a WASI 0.3 command component: erlang_wasm's `wasi_preview3:run_command`.

Wasmtime links WASI 0.2 and 0.3 beside each other, so this is
`wasmtime_wasi_preview2:run_command/3` under erlang_wasm's other name. It needs
a library with WASI 0.3 (`wasmtime:features/0`, `wasi_p3`).
""".

-export([run_command/3]).

-doc #{equiv => wasmtime_wasi_preview2:run_command(Component, Stdin, Options)}.
-spec run_command(
    binary() | wasmtime_component:prepared(),
    binary(),
    wasmtime_wasi_preview2:command_options()
) -> wasmtime_wasi_preview2:command_result().
run_command(Component, Stdin, Options) ->
    wasmtime_wasi_preview2:run_command(Component, Stdin, Options).
