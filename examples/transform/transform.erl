%% User-defined event transforms: a tenant's JavaScript function runs over
%% every event, sandboxed, with a time and memory limit, in a long-lived
%% QuickJS worker that this gen_server owns. See examples/README.md.
%%
%%   1> c("examples/transform/transform.erl").
%%   2> {ok, Engine} = transform:load_engine("priv/qjs-wasi.wasm").
%%   3> {ok, T} = transform:start_link(Engine, "examples/transform/sample_user.js").
%%   4> transform:run(T, #{type => ~"order", customer => ~"acme",
%%                            items => [#{qty => 2, price => 60}]}).
%%   {ok, #{<<"tier">> => <<"gold">>, <<"total">> => 120, ...}}
%%   5> transform:reload(T, {source, ~"export function transform(e) { return e; }"}).
%%
%% One worker per script. Each event is one JSON line in and one out over
%% the worker's streamed stdin and stdout. A script that throws answers
%% {error, {script, Message}} for that event and keeps serving; one that
%% loops is interrupted after `timeout` and the worker restarts.
-module(transform).
-behaviour(gen_server).

-export([load_engine/1, start_link/2, start_link/3, run/2, reload/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_TIMEOUT, 200).
-define(DEFAULT_MEMORY, 32 * 1024 * 1024).

-record(state, {
    engine,
    dir,
    timeout,
    memory,
    worker = undefined
}).

%% Compile the QuickJS WASI build once; every worker instantiates it.
load_engine(Path) ->
    {ok, Bin} = file:read_file(Path),
    wasmtime:compile(Bin).

start_link(Engine, Script) -> start_link(Engine, Script, #{}).

%% Script: a path, or {source, Bin} with the JavaScript itself. Opts:
%% timeout (ms per event, default 200), memory_limit (bytes, default 32 MB).
start_link(Engine, Script, Opts) ->
    gen_server:start_link(?MODULE, {Engine, Script, Opts}, []).

%% Run one event through the script.
run(Server, Event) when is_map(Event) ->
    gen_server:call(Server, {run, Event}, infinity).

%% Replace the script; the next event runs the new one.
reload(Server, Script) ->
    gen_server:call(Server, {reload, Script}, infinity).

stop(Server) -> gen_server:stop(Server).

%% ------------------------------------------------------------- callbacks

init({Engine, Script, Opts}) ->
    Dir = filename:join(
        filename:basedir(user_cache, "erlang_wasmtime"),
        "transform-" ++ integer_to_list(erlang:unique_integer([positive]))
    ),
    ok = filelib:ensure_path(Dir),
    ok = install(Dir, Script),
    State = #state{
        engine = Engine,
        dir = Dir,
        timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
        memory = maps:get(memory_limit, Opts, ?DEFAULT_MEMORY)
    },
    case start_worker(State) of
        {ok, W} -> {ok, State#state{worker = W}};
        {error, Reason} -> {stop, Reason}
    end.

handle_call({run, Event}, _From, State) ->
    case serve(State, Event) of
        {ok, Reply} ->
            {reply, Reply, State};
        {restart, Reply, Alive} ->
            %% Alive: the worker was interrupted and still owes its result;
            %% otherwise it already exited and read_line consumed it.
            Alive andalso stop_worker(State#state.worker),
            case start_worker(State) of
                {ok, W} -> {reply, Reply, State#state{worker = W}};
                {error, Reason} -> {stop, Reason, Reply, State#state{worker = undefined}}
            end
    end;
handle_call({reload, Script}, _From, State) ->
    ok = install(State#state.dir, Script),
    stop_worker(State#state.worker),
    case start_worker(State) of
        {ok, W} -> {reply, ok, State#state{worker = W}};
        {error, Reason} -> {reply, {error, Reason}, State#state{worker = undefined}}
    end.

handle_cast(_, State) -> {noreply, State}.

%% The worker exited on its own (a script that called std.exit, an
%% allocation past the memory limit): the next event starts a fresh one.
handle_info({wasmtime_result, Ref, _, _}, #state{worker = #{ref := Ref}} = State) ->
    {noreply, State#state{worker = undefined}};
handle_info(_, State) ->
    {noreply, State}.

terminate(_, #state{worker = W, dir = Dir}) ->
    stop_worker(W),
    _ = file:del_dir_r(Dir),
    ok.

%% -------------------------------------------------------------- workers

install(Dir, {source, Source}) ->
    ok = file:write_file(filename:join(Dir, "user.js"), Source),
    Runner = filename:join(filename:dirname(?FILE), "runner.js"),
    {ok, _} = file:copy(Runner, filename:join(Dir, "runner.js")),
    ok;
install(Dir, Path) ->
    {ok, Source} = file:read_file(Path),
    install(Dir, {source, Source}).

start_worker(#state{engine = Engine, dir = Dir, memory = Memory}) ->
    case
        wasmtime:instantiate(Engine, #{
            wasi => #{
                args => [~"qjs", ~"/app/runner.js"],
                dirs => [{~"/app", Dir, read}],
                stdin => stream,
                stdout => stream,
                stderr => capture
            },
            stream => self(),
            memory_limit => Memory
        })
    of
        {ok, Inst} ->
            {ok, Req} = wasmtime:call_async(Inst, ~"_start", []),
            {ok, #{inst => Inst, req => Req, ref => wasmtime:ref(Inst)}};
        {error, Reason} ->
            {error, Reason}
    end.

stop_worker(undefined) ->
    ok;
%% End the input so the runner's loop finishes; an interrupted worker
%% answers at once, a stuck one is interrupted.
stop_worker(#{inst := Inst, req := Req}) ->
    ok = wasmtime:close(Inst),
    case wasmtime:await(Inst, Req, 1000) of
        {error, #{kind := timeout}} ->
            _ = wasmtime:interrupt(Inst),
            _ = wasmtime:await(Inst, Req, 1000),
            ok;
        _ ->
            ok
    end.

serve(#state{worker = undefined} = State, Event) ->
    case start_worker(State) of
        {ok, W} -> serve(State#state{worker = W}, Event);
        {error, Reason} -> {ok, {error, Reason}}
    end;
serve(#state{worker = #{inst := Inst, ref := Ref, req := Req}, timeout = Timeout}, Event) ->
    ok = wasmtime:send(Inst, [json:encode(Event), $\n]),
    case read_line(Inst, Ref, Req, Timeout, <<>>) of
        {ok, Line} ->
            {ok,
                case json:decode(Line) of
                    #{~"ok" := null} -> {ok, drop};
                    #{~"ok" := Out} -> {ok, Out};
                    #{~"error" := Msg} -> {error, {script, Msg}}
                end};
        {exited, Result} ->
            {ok, {_, Stderr, _}} = wasmtime:read_output(Inst),
            {restart, {error, {worker_exited, Result, Stderr}}, false};
        timeout ->
            _ = wasmtime:interrupt(Inst),
            {restart, {error, timeout}, true}
    end.

%% One JSON line: QuickJS writes each puts at once, but nothing forbids a
%% script from writing in pieces, so accumulate to the newline.
read_line(Inst, Ref, Req, Timeout, Acc) ->
    receive
        {wasmtime_stream, Ref, stdout, Bytes} ->
            case binary:split(<<Acc/binary, Bytes/binary>>, <<"\n">>) of
                [Line, _] -> {ok, Line};
                [More] -> read_line(Inst, Ref, Req, Timeout, More)
            end;
        {wasmtime_result, Ref, _, Result} ->
            {exited, Result}
    after Timeout -> timeout
    end.
