%% Run JavaScript with QuickJS compiled to WASI. See docs/javascript.md.
%%
%%   1> c("examples/js/js.erl").
%%   2> {ok, Engine} = js:load("qjs-wasi.wasm").
%%   3> js:eval(Engine, ~"console.log(1 + 2)").
%%   {ok, ~"3\n"}
%%   4> {ok, W} = js:serve(Engine, "/srv/scripts", "worker.js").
%%   5> js:ask(W, ~"{\"sku\": \"A1\"}").
%%   {ok, ~"{\"sku\":\"A1\",\"price\":42}\n"}
-module(js).

-export([load/1, eval/2, eval/3, run_file/3, serve/3, ask/2, ask/3, stop/1]).

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

%% Start a script that reads one request per line on stdin and answers one
%% line on stdout, and keep it running. Its output comes to this process.
serve(Engine, Dir, File) ->
    case
        wasmtime:instantiate(Engine, #{
            wasi => #{
                args => [~"qjs", filename:join(~"/app", File)],
                dirs => [{~"/app", Dir, read}],
                stdin => stream,
                stdout => stream,
                stderr => capture
            },
            stream => self(),
            memory_limit => 64 * 1024 * 1024
        })
    of
        {ok, Inst} ->
            {ok, Req} = wasmtime:call_async(Inst, ~"_start", []),
            {ok, #{inst => Inst, req => Req, ref => wasmtime:ref(Inst)}};
        {error, Reason} ->
            {error, Reason}
    end.

ask(Worker, Line) -> ask(Worker, Line, ?DEFAULT_TIMEOUT).

%% One request, one reply line: a streamed stdout is line-buffered in the
%% script, so a stdout message is a whole line.
ask(#{inst := Inst, ref := Ref}, Line, Timeout) ->
    case wasmtime:send(Inst, [Line, $\n]) of
        ok ->
            receive
                {wasmtime_stream, Ref, stdout, Out} -> {ok, Out}
            after Timeout -> {error, timeout}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

%% Close its input; the script ends when its read loop sees end of file.
stop(#{inst := Inst, req := Req}) ->
    ok = wasmtime:close(Inst),
    case wasmtime:await(Inst, Req, ?DEFAULT_TIMEOUT) of
        {ok, []} ->
            ok;
        {error, #{class := exit, status := Status}} ->
            {ok, {_, Err, _}} = wasmtime:read_output(Inst),
            {error, {exit, Status, Err}};
        {error, Reason} ->
            {error, Reason}
    end.

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
