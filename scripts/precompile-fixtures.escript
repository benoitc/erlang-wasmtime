#!/usr/bin/env escript
%% Precompile the runtime-only suite's fixtures on a full build.
%%
%%   escript scripts/precompile-fixtures.escript SrcDir OutDir
%%
%% Every SrcDir/*.wat becomes OutDir/<name>.cwasm through compile/1 and
%% serialize/1. The output is tied to this Wasmtime version and this
%% machine's CPU features, so produce and consume it on the same machine.
main([SrcDir, OutDir]) ->
    Root = filename:dirname(filename:dirname(escript:script_name())),
    true = code:add_patha(filename:join([Root, "_build", "default", "lib", "erlang_wasmtime", "ebin"])),
    case wasmtime:features() of
        #{compiler := true, wat := true} -> ok;
        F -> halt_with("this build cannot compile WAT: ~p", [F])
    end,
    ok = filelib:ensure_path(OutDir),
    Sources = filelib:wildcard(filename:join(SrcDir, "*.wat")),
    Sources =/= [] orelse halt_with("no .wat files in ~s", [SrcDir]),
    lists:foreach(fun(Wat) -> precompile(Wat, OutDir) end, Sources);
main(_) ->
    halt_with("usage: precompile-fixtures.escript SrcDir OutDir", []).

precompile(Wat, OutDir) ->
    {ok, Text} = file:read_file(Wat),
    Out = filename:join(OutDir, filename:basename(Wat, ".wat") ++ ".cwasm"),
    case wasmtime:compile({wat, Text}) of
        {ok, Mod} ->
            {ok, Pre} = wasmtime:serialize(Mod),
            ok = file:write_file(Out, Pre),
            io:format("~s -> ~s (~p bytes)~n", [Wat, Out, byte_size(Pre)]);
        {error, Reason} ->
            halt_with("~s: ~p", [Wat, Reason])
    end.

halt_with(Fmt, Args) ->
    io:format(standard_error, Fmt ++ "~n", Args),
    halt(1).
