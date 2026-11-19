%% Compiled modules, cached node-wide: what `wasmtime:load/1,2` and
%% `wasmtime:unload/1` use. erlang_wasm's `wasm_module_cache`, simpler
%% because a compiled module here is a reference to a NIF resource: the
%% table holds the reference, not megabytes of terms.
%%
%% Identity is the hash of the source and the compile options, so two
%% loaders of the same bytes share one module and either may unload: the
%% entry goes when the last claim does. A claim belongs to the process that
%% loaded, and is given back when that process dies. Dropping an entry does
%% not free the module while an instance or a term still refers to it.
-module(wasmtime_module_cache).
-moduledoc false.
-behaviour(gen_server).

-export([start_link/0, load/2, unload/1, resident/0, claims/1]).
-export([prepared/1, source/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-define(SERVER, ?MODULE).
%% Compiled code is not freed while an entry holds it; the cap turns a
%% loader that never unloads into an error. `max_resident_modules` in the
%% application environment changes it.
-define(DEFAULT_MAX_RESIDENT, 256).
%% Every call is a map update: compiling happens in the caller. A waiter
%% for someone else's compile is answered when that compile ends.
-define(CALL_TIMEOUT, infinity).

-record(state, {
    %% Key => {Module, Holders}
    resident = #{} :: map(),
    %% Module => Key, to unload by module
    keys = #{} :: map(),
    %% Module => {Source, CompileOpts, Prepared | undefined}: what a snapshot
    %% needs, kept for as long as the module is resident
    sources = #{} :: map(),
    %% Key => {CompilerPid, [gen_server:from()]}: who compiles it and who waits
    compiling = #{} :: map(),
    %% Pid => {MonitorRef, #{Key => Count}}
    claims = #{} :: map(),
    max_resident :: pos_integer()
}).

-type state() :: #state{}.

start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec load(binary() | {wat, iodata()}, map()) -> {ok, wasmtime:module_ref()} | wasmtime:error().
load(Source, Opts) ->
    %% compile_key/1 raises on malformed options, as compile/2 does
    Key = crypto:hash(
        sha256, term_to_binary({source_bytes(Source), wasmtime_options:compile_key(Opts)})
    ),
    try gen_server:call(?SERVER, {acquire, Key}, ?CALL_TIMEOUT) of
        {ok, Mod} ->
            {ok, Mod};
        compile_it ->
            %% Outside the server: a large module must not block other loaders.
            Result = wasmtime:compile(Source, Opts),
            gen_server:call(?SERVER, {compiled, Key, Result, {Source, Opts}}, ?CALL_TIMEOUT);
        {error, _} = Error ->
            Error
    catch
        exit:{noproc, _} ->
            refused(not_started, ~"the erlang_wasmtime application is not started")
    end.

-spec unload(wasmtime:module_ref()) -> ok.
unload(Mod) ->
    try
        gen_server:call(?SERVER, {unload, Mod}, ?CALL_TIMEOUT)
    catch
        exit:{noproc, _} -> ok
    end.

-doc "How many modules the cache holds.".
-spec resident() -> non_neg_integer().
resident() -> gen_server:call(?SERVER, resident, ?CALL_TIMEOUT).

-doc "How many claims a process holds, over all modules.".
-spec claims(pid()) -> non_neg_integer().
claims(Pid) -> gen_server:call(?SERVER, {claims, Pid}, ?CALL_TIMEOUT).

-doc "The bytes and compile options a resident module was loaded from.".
-spec source(wasmtime:module_ref()) -> {ok, binary(), map()} | error.
source(Mod) ->
    case find(Mod) of
        {ok, {Source, Opts, _}} -> binary_source(Source, Opts);
        error -> error
    end.

-doc """
The instrumented form of a resident module, for a snapshotable instance:
made on first use, in the caller, and kept with the module.
""".
-spec prepared(wasmtime:module_ref()) -> {ok, map(), binary(), map()} | error | wasmtime:error().
prepared(Mod) ->
    maybe
        {ok, {Source, Opts, Known}} ?= find(Mod),
        {ok, Wasm, Opts} ?= binary_source(Source, Opts),
        {ok, Prepared} ?= prepare(Mod, Wasm, Opts, Known),
        {ok, Prepared, Wasm, Opts}
    end.

prepare(_Mod, _Wasm, _Opts, Known) when is_map(Known) ->
    {ok, Known};
prepare(Mod, Wasm, Opts, undefined) ->
    case wasmtime_preinit:prepare(Wasm, Opts) of
        {ok, Prepared} ->
            ok = gen_server:call(?SERVER, {prepared, Mod, Prepared}, ?CALL_TIMEOUT),
            {ok, Prepared};
        {error, _} = Error ->
            Error
    end.

find(Mod) ->
    try
        gen_server:call(?SERVER, {source, Mod}, ?CALL_TIMEOUT)
    catch
        exit:{noproc, _} -> error
    end.

binary_source({wat, Text}, Opts) ->
    case wasmtime:wat2wasm(Text) of
        {ok, Wasm} -> {ok, Wasm, Opts};
        {error, _} = Error -> Error
    end;
binary_source(Wasm, Opts) ->
    {ok, Wasm, Opts}.

source_bytes({wat, Text}) -> {wat, iolist_to_binary(Text)};
source_bytes(Bin) when is_binary(Bin) -> Bin.

refused(Kind, Message) ->
    {error, #{class => compile, kind => Kind, message => Message}}.

%% ------------------------------------------------------------------ server

-spec init([]) -> {ok, state()}.
init([]) ->
    Max = application:get_env(erlang_wasmtime, max_resident_modules, ?DEFAULT_MAX_RESIDENT),
    {ok, #state{max_resident = Max}}.

handle_call({acquire, Key}, From, S) ->
    acquire(Key, From, S);
handle_call({compiled, Key, Result, Source}, {Pid, _}, S) ->
    {reply, Result, compiled(Key, Result, Source, Pid, S)};
handle_call({unload, Mod}, {Pid, _}, #state{keys = Keys} = S) ->
    case Keys of
        #{Mod := Key} -> {reply, ok, unclaim(Pid, Key, S)};
        _ -> {reply, ok, S}
    end;
handle_call({source, Mod}, _From, #state{sources = Sources} = S) ->
    {reply, maps:find(Mod, Sources), S};
handle_call({prepared, Mod, Prepared}, _From, #state{sources = Sources} = S) ->
    case Sources of
        #{Mod := {Source, Opts, _}} ->
            {reply, ok, S#state{sources = Sources#{Mod := {Source, Opts, Prepared}}}};
        _ ->
            {reply, ok, S}
    end;
handle_call(resident, _From, #state{resident = Resident} = S) ->
    {reply, map_size(Resident), S};
handle_call({claims, Pid}, _From, #state{claims = Claims} = S) ->
    {_, Held} = maps:get(Pid, Claims, {undefined, #{}}),
    {reply, lists:sum(maps:values(Held)), S}.

handle_cast(_Msg, S) -> {noreply, S}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    {noreply, gone(Pid, S)};
handle_info(_Msg, S) ->
    {noreply, S}.

%% Resident: a claim. Being compiled: wait for that compile instead of
%% doing it twice. Otherwise the caller compiles, if there is room.
acquire(Key, {Pid, _} = From, #state{resident = Resident, compiling = Compiling} = S) ->
    case {Resident, Compiling} of
        {#{Key := {Mod, Holders}}, _} ->
            S1 = S#state{resident = Resident#{Key := {Mod, Holders + 1}}},
            {reply, {ok, Mod}, claim(Pid, Key, S1)};
        {_, #{Key := {Compiler, Waiters}}} ->
            Waiting = Compiling#{Key := {Compiler, Waiters ++ [From]}},
            {noreply, watch(Pid, S#state{compiling = Waiting})};
        _ when map_size(Resident) + map_size(Compiling) >= S#state.max_resident ->
            Message = ~"the module cache is full: unload modules you no longer use",
            {reply, refused(cache_full, Message), S};
        _ ->
            {reply, compile_it, watch(Pid, S#state{compiling = Compiling#{Key => {Pid, []}}})}
    end.

%% The compiler reports. A caller that is no longer the compiler of that
%% key (the server restarted meanwhile) keeps its module and takes no claim.
compiled(Key, Result, Source, Pid, #state{compiling = Compiling} = S) ->
    case maps:take(Key, Compiling) of
        {{Pid, Waiters}, Rest} ->
            Pids = [Pid | [W || {W, _} <- Waiters]],
            S1 = remember(Result, Source, S#state{compiling = Rest}),
            published(Key, Result, Pids, Waiters, S1);
        _ ->
            S
    end.

%% A compile ended: on success the module becomes resident with one claim
%% per process that asked, on failure every waiter gets the error.
published(Key, {ok, Mod} = Result, Pids, Waiters, #state{resident = Resident, keys = Keys} = S) ->
    [gen_server:reply(W, Result) || W <- Waiters],
    S1 = S#state{resident = Resident#{Key => {Mod, length(Pids)}}, keys = Keys#{Mod => Key}},
    lists:foldl(fun(P, Acc) -> claim(P, Key, Acc) end, S1, Pids);
published(_Key, {error, _} = Result, _Pids, Waiters, S) ->
    [gen_server:reply(W, Result) || W <- Waiters],
    S.

remember({ok, Mod}, {Source, Opts}, #state{sources = Sources} = S) ->
    S#state{sources = Sources#{Mod => {Source, Opts, undefined}}};
remember(_Error, _Source, S) ->
    S.

watch(Pid, #state{claims = Claims} = S) when is_map_key(Pid, Claims) -> S;
watch(Pid, #state{claims = Claims} = S) ->
    S#state{claims = Claims#{Pid => {erlang:monitor(process, Pid), #{}}}}.

claim(Pid, Key, S) ->
    #state{claims = Claims} = S1 = watch(Pid, S),
    {Mon, Held} = maps:get(Pid, Claims),
    S1#state{claims = Claims#{Pid := {Mon, maps:update_with(Key, fun(N) -> N + 1 end, 1, Held)}}}.

%% One claim of Pid on Key goes; a process that holds none is not charged.
unclaim(Pid, Key, #state{claims = Claims} = S) ->
    case Claims of
        #{Pid := {Mon, #{Key := N} = Held}} ->
            Held1 =
                case N of
                    1 -> maps:remove(Key, Held);
                    _ -> Held#{Key := N - 1}
                end,
            release(Key, 1, S#state{claims = Claims#{Pid := {Mon, Held1}}});
        _ ->
            S
    end.

release(Key, Count, #state{resident = Resident, keys = Keys} = S) ->
    case Resident of
        #{Key := {Mod, Holders}} when Holders =< Count ->
            S#state{
                resident = maps:remove(Key, Resident),
                keys = maps:remove(Mod, Keys),
                sources = maps:remove(Mod, S#state.sources)
            };
        #{Key := {Mod, Holders}} ->
            S#state{resident = Resident#{Key := {Mod, Holders - Count}}};
        _ ->
            S
    end.

%% A process died: its claims go back, the compiles it owned pass to the
%% first waiter, and it stops waiting for the others.
gone(Pid, #state{claims = Claims, compiling = Compiling} = S) ->
    {Held, Claims1} =
        case maps:take(Pid, Claims) of
            {{_Mon, H}, Rest} -> {H, Rest};
            error -> {#{}, Claims}
        end,
    S1 = maps:fold(fun release/3, S#state{claims = Claims1}, Held),
    S1#state{compiling = maps:filtermap(fun(_Key, Entry) -> handover(Pid, Entry) end, Compiling)}.

handover(Pid, {Pid, []}) ->
    false;
handover(Pid, {Pid, [{Next, _} = From | Waiters]}) ->
    gen_server:reply(From, compile_it),
    {true, {Next, Waiters}};
handover(Pid, {Compiler, Waiters}) ->
    {true, {Compiler, [W || {P, _} = W <- Waiters, P =/= Pid]}}.
