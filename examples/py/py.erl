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

%% Opts: timeout (ms), env ([{Name, Value}]), memory_limit (bytes),
%% dirs (extra [{Guest, Host, read | write}] the script may reach).
eval(Py, Code, Opts) ->
    run(Py, [~"python", ~"-c", Code], Opts).

%% Run a script from Dir, visible to the script as /app.
run_file(Py, Dir, File) ->
    run(Py, [~"python", filename:join(~"/app", File)], #{dirs => [{~"/app", Dir, read}]}).

run(#{mod := Mod, dir := Dir}, Args, Opts) ->
    Out = temp_file("out"),
    Err = temp_file("err"),
    Result =
        case
            wasmtime:instantiate(Mod, #{
                wasi => #{
                    args => Args,
                    env => maps:get(env, Opts, []),
                    dirs => [{~"/", Dir, read} | maps:get(dirs, Opts, [])],
                    stdout => {file, Out},
                    stderr => {file, Err}
                },
                memory_limit => maps:get(memory_limit, Opts, 512 * 1024 * 1024)
            })
        of
            {ok, Inst} ->
                case
                    wasmtime:call(Inst, ~"_start", [], #{
                        timeout => maps:get(timeout, Opts, ?DEFAULT_TIMEOUT)
                    })
                of
                    {ok, []} ->
                        {ok, read(Out)};
                    {error, #{class := exit, status := Status}} ->
                        {error, {exit, Status, read(Err)}};
                    {error, #{kind := timeout}} ->
                        {error, timeout};
                    {error, Reason} ->
                        {error, Reason}
                end;
            {error, Reason} ->
                {error, Reason}
        end,
    file:delete(Out),
    file:delete(Err),
    Result.

read(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> Bin;
        _ -> <<>>
    end.

temp_file(Tag) ->
    Dir = filename:basedir(user_cache, "erlang_wasmtime"),
    ok = filelib:ensure_path(Dir),
    filename:join(Dir, io_lib:format("py-~s-~p", [Tag, erlang:unique_integer([positive])])).
