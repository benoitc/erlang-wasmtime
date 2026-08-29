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

%% Opts: timeout (ms), env ([{Name, Value}]), memory_limit (bytes), stdin
%% (bytes the script reads).
eval(Engine, Script, Opts) ->
    run(Engine, [~"qjs", ~"-e", Script], #{}, Opts).

%% Run a script file. The guest sees Dir as /app and nothing else.
run_file(Engine, Dir, File) ->
    run(Engine, [~"qjs", filename:join(~"/app", File)], #{dirs => [{~"/app", Dir, read}]}, #{}).

run(Engine, Args, Wasi, Opts) ->
    case
        wasmtime:instantiate(Engine, #{
            wasi => Wasi#{
                args => Args,
                env => maps:get(env, Opts, []),
                stdin => {binary, maps:get(stdin, Opts, <<>>)},
                stdout => capture,
                stderr => capture
            },
            memory_limit => maps:get(memory_limit, Opts, 64 * 1024 * 1024)
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
