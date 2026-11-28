-module(wasmtime_actor_type).
-moduledoc false.
%% wasmtime_actor's message types: which ones can travel between instances,
%% and whether a term is a value of one, before it is queued.

-export([plain/1, fits/2]).

%% A message type that can cross from one instance to another: values only.
plain(T) when
    T =:= u8;
    T =:= u16;
    T =:= u32;
    T =:= u64;
    T =:= s8;
    T =:= s16;
    T =:= s32;
    T =:= s64;
    T =:= f32;
    T =:= f64;
    T =:= bool;
    T =:= char;
    T =:= string
->
    true;
plain({list, T}) ->
    plain(T);
plain({option, T}) ->
    plain(T);
plain({tuple, Ts}) when is_list(Ts) -> lists:all(fun plain/1, Ts);
plain({record, Fs}) when is_list(Fs) ->
    lists:all(
        fun
            ({N, T}) -> is_binary(N) andalso plain(T);
            (_) -> false
        end,
        Fs
    );
plain({variant, Cs}) when is_list(Cs) ->
    lists:all(
        fun
            ({N, none}) -> is_binary(N);
            ({N, T}) -> is_binary(N) andalso plain(T);
            (_) -> false
        end,
        Cs
    );
plain({result, Ok, Err}) ->
    payload(Ok) andalso payload(Err);
plain({enum, Ns}) when is_list(Ns) -> lists:all(fun is_binary/1, Ns);
plain({flags, Ns}) when is_list(Ns) -> lists:all(fun is_binary/1, Ns);
plain(_) ->
    false.

payload(none) -> true;
payload(T) -> plain(T).

%% Whether `V' is a value of type `T', in the shapes `wasm_canon' lowers.
fits(u8, V) ->
    int_in(V, 0, 16#FF);
fits(u16, V) ->
    int_in(V, 0, 16#FFFF);
fits(u32, V) ->
    int_in(V, 0, 16#FFFFFFFF);
fits(u64, V) ->
    int_in(V, 0, 16#FFFFFFFFFFFFFFFF);
fits(s8, V) ->
    int_in(V, -16#80, 16#7F);
fits(s16, V) ->
    int_in(V, -16#8000, 16#7FFF);
fits(s32, V) ->
    int_in(V, -16#80000000, 16#7FFFFFFF);
fits(s64, V) ->
    int_in(V, -16#8000000000000000, 16#7FFFFFFFFFFFFFFF);
fits(F, V) when F =:= f32; F =:= f64 -> is_float(V);
fits(bool, V) ->
    is_boolean(V);
fits(char, V) ->
    int_in(V, 0, 16#10FFFF) andalso not int_in(V, 16#D800, 16#DFFF);
fits(string, V) ->
    is_binary(V) andalso unicode:characters_to_binary(V) =:= V;
fits({list, u8}, V) ->
    is_binary(V);
fits({list, T}, V) ->
    is_list(V) andalso lists:all(fun(E) -> fits(T, E) end, V);
fits({option, _T}, none) ->
    true;
fits({option, T}, {some, V}) ->
    fits(T, V);
fits({tuple, Ts}, V) ->
    is_tuple(V) andalso tuple_size(V) =:= length(Ts) andalso
        lists:all(
            fun({T, E}) -> fits(T, E) end,
            lists:zip(Ts, tuple_to_list(V))
        );
fits({record, Fs}, V) ->
    is_map(V) andalso map_size(V) =:= length(Fs) andalso
        lists:all(
            fun({N, T}) ->
                is_map_key(N, V) andalso
                    fits(T, map_get(N, V))
            end,
            Fs
        );
fits({variant, Cs}, {N, P}) ->
    case lists:keyfind(N, 1, Cs) of
        {N, T} -> fits_payload(T, P);
        false -> false
    end;
fits({result, Ok, _Err}, {ok, P}) ->
    fits_payload(Ok, P);
fits({result, _Ok, Err}, {error, P}) ->
    fits_payload(Err, P);
fits({enum, Ns}, V) ->
    lists:member(V, Ns);
fits({flags, Ns}, V) ->
    is_list(V) andalso lists:all(fun(N) -> lists:member(N, Ns) end, V);
fits(_T, _V) ->
    false.

fits_payload(none, P) -> P =:= undefined;
fits_payload(T, P) -> fits(T, P).

int_in(V, Lo, Hi) -> is_integer(V) andalso V >= Lo andalso V =< Hi.
