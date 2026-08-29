%% Run JavaScript with QuickJS compiled to WASI. See docs/javascript.md.
%%
%%   1> c("examples/js/js.erl").
%%   2> {ok, Engine} = js:load("qjs-wasi.wasm").
%%   3> js:eval(Engine, ~"console.log(1 + 2)").
%%   {ok, ~"3\n"}
-module(js).

-export([load/1, eval/2, eval/3, run_file/3]).

-define(DEFAULT_TIMEOUT, 5000).

%% Compile the engine once; every eval gets a fresh instance from it.
load(Path) ->
    {ok, Bin} = file:read_file(Path),
    wasmtime:compile(Bin).

eval(Engine, Script) -> eval(Engine, Script, #{}).

%% Opts: timeout (ms), env ([{Name, Value}]), memory_limit (bytes).
eval(Engine, Script, Opts) ->
    run(Engine, [~"qjs", ~"-e", Script], #{}, Opts).

%% Run a script file. The guest sees Dir as /app and nothing else.
run_file(Engine, Dir, File) ->
    run(Engine, [~"qjs", filename:join(~"/app", File)], #{dirs => [{~"/app", Dir, read}]}, #{}).

run(Engine, Args, Wasi, Opts) ->
    Out = temp_file("out"),
    Err = temp_file("err"),
    Result =
        case
            wasmtime:instantiate(Engine, #{
                wasi => Wasi#{
                    args => Args,
                    env => maps:get(env, Opts, []),
                    stdout => {file, Out},
                    stderr => {file, Err}
                },
                memory_limit => maps:get(memory_limit, Opts, 64 * 1024 * 1024)
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
    filename:join(Dir, io_lib:format("js-~s-~p", [Tag, erlang:unique_integer([positive])])).
