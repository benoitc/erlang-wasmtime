-module(wasmtime_wasi).
-moduledoc """
Run a WASI program and get its exit status and output back: erlang_wasm's
`wasi`.

Use this when your guest is a program with a `main` rather than a library of
exported functions.

```erlang
{ok, Mod} = wasmtime:load_file("hello.wasm"),
{ok, 0, Stdout, _Stderr} =
    wasmtime_wasi:run(Mod, #{args => [~"hello"],
                             dirs => [{~"/data", "/srv/app/data", read}]}).
```

The configuration is the `wasi` option of `wasmtime:instantiate/3`
(`t:wasmtime:wasi_options/0`): leave a key out and the program does not have
that capability.
""".

-export([run/1, run/2, imports/1]).

-doc #{equiv => run(Module, #{})}.
-spec run(wasmtime:module_ref()) -> {ok, integer(), binary(), binary()} | wasmtime:error().
run(Module) -> run(Module, #{}).

-doc """
Instantiate a core module, call `_start`, and answer its exit status and
output.

A program that returns from `_start` without calling `proc_exit` exits 0. A
trap that is not an exit is `{error, Error}`. Any `stdout` or `stderr` in the
configuration is replaced: the output is captured, up to `output_limit` bytes
per stream.
""".
-spec run(wasmtime:module_ref(), map()) ->
    {ok, integer(), binary(), binary()} | wasmtime:error().
run(Module, Config) ->
    Captured = Config#{stdout => capture, stderr => capture},
    maybe
        {ok, Inst} ?= wasmtime:instantiate(Module, #{}, #{wasi => Captured}),
        Result = wasmtime:call(Inst, ~"_start", []),
        {ok, {Out, Err, _Dropped}} = wasmtime:read_output(Inst),
        ok = wasmtime:destroy(Inst),
        case Result of
            {ok, _} ->
                {ok, 0, Out, Err};
            {error, Error} ->
                case wasmtime_wasi_preview1:exit_code(Error) of
                    {ok, Code} -> {ok, Code, Out, Err};
                    error -> Result
                end
        end
    end.

-doc """
WASI as part of an import map, for code written around erlang_wasm:

```erlang
Imports = maps:merge(wasmtime_wasi:imports(Config), HostFunctions),
{ok, Inst} = wasmtime:instantiate(Mod, Imports, #{}).
```

The map holds one entry standing for the configuration, which
`instantiate` turns into the `wasi` option. Wasmtime implements WASI, so
there is no function per syscall in it to wrap or remove; a host function of
yours under a WASI name still takes its place.
""".
-spec imports(map()) -> map().
imports(Config) -> wasmtime_wasi_config:imports(Config).
