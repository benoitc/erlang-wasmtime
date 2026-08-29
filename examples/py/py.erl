%% Run Python with CPython compiled to WASI. See docs/python.md.
%%
%%   1> c("examples/py/py.erl").
%%   2> {ok, Py} = py:load("/opt/python-wasi").   % holds python.wasm and lib/
%%   3> py:eval(Py, ~"print(sum(range(10)))").
%%   {ok, ~"45\n"}
-module(py).

-export([load/1, eval/2, eval/3, run_file/3]).

-define(DEFAULT_TIMEOUT, 30000).

%% Compile the interpreter once. Dir holds python.wasm and lib/python3.x;
%% it is mounted read-only at / so the interpreter finds its stdlib.
load(Dir) ->
    {ok, Bin} = file:read_file(filename:join(Dir, "python.wasm")),
    case wasmtime:compile(Bin) of
        {ok, Mod} -> {ok, #{mod => Mod, dir => Dir}};
        {error, _} = Error -> Error
    end.

eval(Py, Code) -> eval(Py, Code, #{}).

%% Opts: timeout (ms), env ([{Name, Value}]), memory_limit (bytes), stdin
%% (bytes the script reads), dirs (extra [{Guest, Host, read | write}]).
eval(Py, Code, Opts) ->
    run(Py, [~"python", ~"-c", Code], Opts).

%% Run a script from Dir, visible to the script as /app.
run_file(Py, Dir, File) ->
    run(Py, [~"python", filename:join(~"/app", File)], #{dirs => [{~"/app", Dir, read}]}).

run(#{mod := Mod, dir := Dir}, Args, Opts) ->
    case
        wasmtime:instantiate(Mod, #{
            wasi => #{
                args => Args,
                env => maps:get(env, Opts, []),
                dirs => [{~"/", Dir, read} | maps:get(dirs, Opts, [])],
                stdin => {binary, maps:get(stdin, Opts, <<>>)},
                stdout => capture,
                stderr => capture
            },
            memory_limit => maps:get(memory_limit, Opts, 512 * 1024 * 1024)
        })
    of
        {ok, Inst} ->
            Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
            Result = wasmtime:call(Inst, ~"_start", [], #{timeout => Timeout}),
            {ok, {Out, Err, _Dropped}} = wasmtime:read_output(Inst),
            case Result of
                {ok, []} -> {ok, Out};
                {error, #{class := exit, status := Status}} -> {error, {exit, Status, Err}};
                {error, #{kind := timeout}} -> {error, timeout};
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.
