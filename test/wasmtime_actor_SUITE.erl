%% wasmtime_actor, erlang_wasm's wasmtime_actor: erlang_wasm's own suite and
%% guest (wasmtime_component_SUITE_data/actor.component.wasm). The guest's
%% `add(n)' keeps a running total and posts `added(total)'; `added(n)' reports
%% n through a `note' import; a refused post is reported through `note' too,
%% and `boom' traps.
-module(wasmtime_actor_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").

-define(MSG, {variant, [{~"add", u32}, {~"added", u32}, {~"boom", none}]}).
-define(REFUSED_FULL, 16#FFFFFF00).
-define(REFUSED_CLOSED, 16#FFFFFF01).

all() ->
    [
        one_sender_keeps_its_order,
        each_sender_keeps_its_order_among_many,
        actors_keep_their_state_apart,
        admission_is_bounded_under_contention,
        an_actor_posts_to_itself,
        a_post_to_itself_fits_in_a_full_queue,
        a_stopped_actor_is_closed,
        a_killed_actor_is_forgotten,
        the_guest_sees_closed,
        the_guest_sees_full,
        a_trap_stops_the_actor,
        a_supervisor_restarts_a_trapped_actor_fresh,
        a_registry_restart_keeps_watching,
        a_message_that_does_not_fit_raises,
        a_bad_start_is_an_error,
        a_prepared_component_starts_actors,
        a_restarted_actor_takes_messages_once_its_name_resolves,
        a_taken_name_is_refused
    ].

init_per_suite(Config0) ->
    case wasmtime_test:needs([compiler, components], Config0) of
        {skip, _} = Skip ->
            Skip;
        Config ->
            {ok, _} = application:ensure_all_started(erlang_wasmtime),
            {ok, Bin} = file:read_file(fixture_path(Config)),
            [{component, Bin} | Config]
    end.

end_per_suite(_Config) -> ok.

%% Each case's actors are linked to its process and stop when it ends. Wait
%% for them, so no case counts another's pages or rows.
init_per_testcase(_Case, Config) ->
    ok = until(fun() -> ets:info(wasmtime_actors, size) =:= 0 end),
    timer:sleep(20),
    Config.

end_per_testcase(_Case, _Config) -> ok.

%%% ----------------------------------------------------------------- cases ---

%% The totals posted back are prefix sums, so their differences are the
%% messages in the order the actor handled them.
one_sender_keeps_its_order(Config) ->
    A = actor(Config, a, #{}),
    Ns = [rand:uniform(1000) || _ <- lists:seq(1, 300)],
    [ok = wasmtime_actor:send(A, add(N)) || N <- Ns],
    ?assertEqual(Ns, deltas(posted(a, length(Ns)))).

%% Eight senders at once. Their messages interleave, but each sender's own
%% come out in the order it sent them.
each_sender_keeps_its_order_among_many(Config) ->
    A = actor(Config, a, #{}),
    Senders = 8,
    Each = 100,
    Go = make_ref(),
    Pids = [
        spawn_link(fun() ->
            receive
                Go -> ok
            end,
            [
                ok = wasmtime_actor:send(A, add(S * 1000 + I))
             || I <- lists:seq(1, Each)
            ]
        end)
     || S <- lists:seq(1, Senders)
    ],
    [P ! Go || P <- Pids],
    Got = deltas(posted(a, Senders * Each)),
    [
        ?assertEqual(
            [S * 1000 + I || I <- lists:seq(1, Each)],
            [V || V <- Got, V div 1000 =:= S]
        )
     || S <- lists:seq(1, Senders)
    ].

actors_keep_their_state_apart(Config) ->
    A = actor(Config, a, #{}),
    B = actor(Config, b, #{}),
    ok = wasmtime_actor:send(A, add(2)),
    ok = wasmtime_actor:send(A, add(3)),
    ok = wasmtime_actor:send(B, add(3)),
    ?assertEqual([2, 5], [N || {_, N} <- posted(a, 2)]),
    ?assertEqual([3], [N || {_, N} <- posted(b, 1)]).

%% A suspended actor takes nothing out of its queue, so of everything sixteen
%% senders try at once exactly `capacity' is admitted, and that much is
%% handled once it runs again.
admission_is_bounded_under_contention(Config) ->
    Cap = 10,
    A = actor(Config, a, #{capacity => Cap}),
    ok = sys:suspend(A),
    Self = self(),
    Go = make_ref(),
    Pids = [
        spawn_link(fun() ->
            receive
                Go -> ok
            end,
            Self !
                {answers, [
                    wasmtime_actor:send(A, add(1))
                 || _ <- lists:seq(1, 50)
                ]}
        end)
     || _ <- lists:seq(1, 16)
    ],
    [P ! Go || P <- Pids],
    Answers = lists:append([
        receive
            {answers, L} -> L
        end
     || _ <- Pids
    ]),
    ?assertEqual(Cap, length([ok || ok <- Answers])),
    ?assertEqual(
        16 * 50 - Cap,
        length([full || {error, full} <- Answers])
    ),
    ok = sys:resume(A),
    ?assertEqual(lists:seq(1, Cap), [N || {_, N} <- posted(a, Cap)]),
    nothing_more(),
    %% Handled, so the room is back.
    ok = wasmtime_actor:send(A, add(1)),
    ?assertEqual([Cap + 1], [N || {_, N} <- posted(a, 1)]).

%% `added' comes back to the actor that posted it, which notes it: the post
%% did not wait for the actor, which was busy posting.
an_actor_posts_to_itself(Config) ->
    A = actor(Config, a, #{to => self}),
    ok = wasmtime_actor:send(A, add(5)),
    ok = wasmtime_actor:send(A, add(2)),
    ?assertEqual([5, 7], notes(a, 2)).

%% The message being handled has left the queue, so a handler that posts to
%% itself has room even when the queue holds one.
a_post_to_itself_fits_in_a_full_queue(Config) ->
    A = actor(Config, a, #{to => self, capacity => 1}),
    ok = wasmtime_actor:send(A, add(4)),
    ?assertEqual([4], notes(a, 1)).

a_stopped_actor_is_closed(Config) ->
    A = actor(Config, a, #{register => actor_suite_a}),
    ok = gen_server:stop(A),
    ?assertEqual({error, closed}, wasmtime_actor:send(A, add(1))),
    ?assertEqual({error, closed}, wasmtime_actor:send(actor_suite_a, add(1))),
    ?assertEqual({error, closed}, wasmtime_actor:send(never_started, add(1))),
    ?assertEqual({error, closed}, wasmtime_actor:send(self(), add(1))).

%% A kill skips `terminate/2'; the registry deletes the row instead.
a_killed_actor_is_forgotten(Config) ->
    A = actor(Config, a, #{}),
    unlink(A),
    Mon = monitor(process, A),
    exit(A, kill),
    receive
        {'DOWN', Mon, process, A, killed} -> ok
    end,
    ok = until(fun() -> ets:lookup(wasmtime_actors, A) =:= [] end),
    ?assertEqual({error, closed}, wasmtime_actor:send(A, add(1))).

the_guest_sees_closed(Config) ->
    Gone = actor(Config, gone, #{}),
    ok = gen_server:stop(Gone),
    A = actor(Config, a, #{to => Gone}),
    ok = wasmtime_actor:send(A, add(1)),
    ?assertEqual([?REFUSED_CLOSED], notes(a, 1)),
    %% No destination at all is the same answer.
    B = actor(Config, b, #{to => undefined}),
    ok = wasmtime_actor:send(B, add(1)),
    ?assertEqual([?REFUSED_CLOSED], notes(b, 1)).

the_guest_sees_full(Config) ->
    Dest = actor(Config, dest, #{capacity => 1}),
    ok = sys:suspend(Dest),
    ok = wasmtime_actor:send(Dest, add(1)),
    A = actor(Config, a, #{to => Dest}),
    ok = wasmtime_actor:send(A, add(1)),
    ?assertEqual([?REFUSED_FULL], notes(a, 1)),
    ok = sys:resume(Dest).

a_trap_stops_the_actor(Config) ->
    process_flag(trap_exit, true),
    A = actor(Config, a, #{}),
    ok = wasmtime_actor:send(A, add(1)),
    _ = posted(a, 1),
    ok = wasmtime_actor:send(A, {~"boom", undefined}),
    Reason =
        receive
            {'EXIT', A, R} -> R
        after 5000 -> error(no_exit)
        end,
    ?assertMatch({handle_failed, #{class := trap}}, Reason),
    ?assertEqual([], ets:lookup(wasmtime_actors, A)),
    ?assertEqual({error, closed}, wasmtime_actor:send(A, add(1))).

%% The restarted actor has a new instance: its total starts again.
a_supervisor_restarts_a_trapped_actor_fresh(Config) ->
    Name = actor_suite_sup_a,
    Child = #{
        id => a,
        start =>
            {wasmtime_actor, start_link, [
                ?config(component, Config),
                opts(a, #{register => Name})
            ]}
    },
    {ok, Sup} = supervisor:start_link(?MODULE, [Child]),
    unlink(Sup),
    try
        Old = whereis(Name),
        ok = wasmtime_actor:send(Name, add(4)),
        ?assertEqual([4], [N || {_, N} <- posted(a, 1)]),
        Mon = monitor(process, Old),
        ok = wasmtime_actor:send(Name, {~"boom", undefined}),
        receive
            {'DOWN', Mon, process, Old, Why} ->
                ?assertMatch({handle_failed, #{class := trap}}, Why)
        after 5000 ->
            error(no_exit)
        end,
        ok = until(fun() ->
            is_pid(whereis(Name)) andalso
                whereis(Name) =/= Old
        end),
        ok = wasmtime_actor:send(Name, add(1)),
        ?assertEqual([1], [N || {_, N} <- posted(a, 1)])
    after
        exit(Sup, shutdown)
    end.

%% The registry restarts with the table intact and watches every actor
%% again, so one killed afterwards is still forgotten.
a_registry_restart_keeps_watching(Config) ->
    A = actor(Config, a, #{}),
    unlink(A),
    Old = whereis(wasmtime_actor_registry),
    exit(Old, kill),
    ok = until(fun() ->
        is_pid(whereis(wasmtime_actor_registry)) andalso
            whereis(wasmtime_actor_registry) =/= Old
    end),
    _ = sys:get_state(wasmtime_actor_registry),
    ?assertEqual(ok, wasmtime_actor:send(A, add(1))),
    exit(A, kill),
    ok = until(fun() -> ets:lookup(wasmtime_actors, A) =:= [] end).

a_message_that_does_not_fit_raises(Config) ->
    A = actor(Config, a, #{}),
    [
        ?assertError(badarg, wasmtime_actor:send(A, Bad))
     || Bad <- [
            {~"add", -1},
            {~"add", 1 bsl 32},
            {~"nope", 1},
            {~"boom", 1},
            add,
            {~"add", 1.0}
        ]
    ],
    %% Nothing was queued, and the actor is still there.
    ok = wasmtime_actor:send(A, add(1)),
    ?assertEqual([1], [N || {_, N} <- posted(a, 1)]).

a_bad_start_is_an_error(Config) ->
    process_flag(trap_exit, true),
    C = ?config(component, Config),
    ?assertEqual({error, no_message_type}, wasmtime_actor:start_link(C, #{})),
    ?assertMatch(
        {error, {bad_message_type, _}},
        wasmtime_actor:start_link(C, #{message => {own, 0}})
    ),
    ?assertMatch(
        {error, {bad_message_type, _}},
        wasmtime_actor:start_link(C, #{message => {list, {stream, u8}}})
    ),
    ?assertMatch(
        {error, {bad_capacity, 0}},
        wasmtime_actor:start_link(C, opts(a, #{capacity => 0}))
    ),
    %% Without `note' the fixture does not instantiate.
    ?assertMatch(
        {error, _},
        wasmtime_actor:start_link(C, #{message => ?MSG})
    ).

%% The fixture imports its message types as `(type (eq ...))', as every
%% world that `use's an interface's types does. `prepare/1' used to refuse
%% that import, so a supervisor could not prepare such a guest once.
a_prepared_component_starts_actors(Config) ->
    {ok, Prepared} = wasmtime_component:prepare(?config(component, Config)),
    A = actor_from(Prepared, a, #{}),
    B = actor_from(Prepared, b, #{}),
    ok = wasmtime_actor:send(A, add(2)),
    ok = wasmtime_actor:send(B, add(7)),
    ?assertEqual([2], [N || {_, N} <- posted(a, 1)]),
    ?assertEqual([7], [N || {_, N} <- posted(b, 1)]).

%% A sender that looks the name up the moment the supervisor has restarted
%% the actor must find a queue behind it. The name used to be registered
%% before the queue existed, and a send in between answered `closed'.
a_restarted_actor_takes_messages_once_its_name_resolves(Config) ->
    Name = actor_suite_race,
    Child = #{
        id => a,
        start =>
            {wasmtime_actor, start_link, [
                ?config(component, Config),
                opts(a, #{register => Name})
            ]}
    },
    {ok, Sup} = supervisor:start_link(?MODULE, {1000, [Child]}),
    unlink(Sup),
    try
        [
            begin
                Old = whereis(Name),
                exit(Old, kill),
                New = spin(Name, Old),
                ?assertEqual(ok, wasmtime_actor:send(New, add(1)))
            end
         || _ <- lists:seq(1, 50)
        ]
    after
        exit(Sup, shutdown)
    end.

a_taken_name_is_refused(Config) ->
    A = actor(Config, a, #{register => actor_suite_taken}),
    ?assertEqual(
        {error, {already_started, A}},
        wasmtime_actor:start_link(
            ?config(component, Config),
            opts(b, #{
                register =>
                    actor_suite_taken
            })
        )
    ),
    ?assertEqual(A, whereis(actor_suite_taken)).

%%% --------------------------------------------------------------- helpers ---

init({Intensity, Children}) ->
    {ok, {#{strategy => one_for_one, intensity => Intensity, period => 10}, Children}};
init(Children) ->
    init({5, Children}).

%% Whatever the name resolves to first that is not `Old', without sleeping.
spin(Name, Old) ->
    spin(Name, Old, erlang:monotonic_time(millisecond) + 5000).

spin(Name, Old, Deadline) ->
    case whereis(Name) of
        Pid when is_pid(Pid), Pid =/= Old ->
            Pid;
        _ ->
            erlang:monotonic_time(millisecond) < Deadline orelse
                error(no_restart),
            erlang:yield(),
            spin(Name, Old, Deadline)
    end.

actor(Config, Tag, Extra) ->
    actor_from(?config(component, Config), Tag, Extra).

actor_from(Component, Tag, Extra) ->
    {ok, Pid} = wasmtime_actor:start_link(Component, opts(Tag, Extra)),
    Pid.

%% Posts and notes come to the test process, tagged with the actor's tag.
opts(Tag, Extra) ->
    Self = self(),
    Note = wasmtime_component:import_fun(
        {[u32], none}, fun([N]) ->
            Self ! {note, Tag, N},
            ok
        end
    ),
    maps:merge(
        #{
            message => ?MSG,
            to => fun(M) ->
                Self ! {posted, Tag, M},
                ok
            end,
            imports => #{{~"$root", ~"note"} => Note}
        },
        Extra
    ).

add(N) -> {~"add", N}.

posted(Tag, N) ->
    [
        receive
            {posted, Tag, {~"added", T}} -> {Tag, T}
        after 5000 -> error({missing_post, Tag})
        end
     || _ <- lists:seq(1, N)
    ].

notes(Tag, N) ->
    [
        receive
            {note, Tag, V} -> V
        after 5000 -> error({missing_note, Tag})
        end
     || _ <- lists:seq(1, N)
    ].

deltas(Posted) ->
    Totals = [T || {_, T} <- Posted],
    [B - A || {A, B} <- lists:zip([0 | lists:droplast(Totals)], Totals)].

nothing_more() ->
    receive
        {posted, _, _} = M -> error({unexpected, M})
    after 100 -> ok
    end.

until(F) -> until(F, 500).
until(_F, 0) ->
    error(timeout);
until(F, N) ->
    case F() of
        true ->
            ok;
        false ->
            timer:sleep(10),
            until(F, N - 1)
    end.

fixture_path(Config) ->
    Dir = string:replace(?config(data_dir, Config), "actor_SUITE", "component_SUITE"),
    filename:join(unicode:characters_to_list(Dir), "actor.component.wasm").
