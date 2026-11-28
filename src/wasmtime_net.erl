-module(wasmtime_net).
-moduledoc false.
%% A network grant, erlang_wasm's `wasi_net` form, turned into the rules the
%% NIF hands to Wasmtime, which checks every address against them. A grant
%% that cannot be read raises `{bad_net_grant, Term}`: it is the caller's
%% mistake, and they should hear of it here and not as a refused connection.

-export([grant/1]).

-export_type([nif_grant/0, net/0]).

%% what erlang_wasm's `net` and `network` take
-type net() :: #{
    connect => [{tcp | udp, term(), term()}],
    listen => [{tcp | udp, term(), term()}],
    resolve => allow | deny,
    tcp => boolean(),
    udp => boolean()
}.

%% {Udp, Listen, Address, PrefixBits, FirstPort, LastPort}
-type rule() :: {0 | 1, 0 | 1, binary(), 0..128, 0..65535, 0..65535}.

-type nif_grant() :: none | all | {rules, boolean(), boolean(), boolean(), [rule()]}.

%% erlang_wasm's `max_sockets` and `timeout` have no counterpart, and are
%% answered as keys to refuse.
-spec grant(none | all | net()) -> {ok, nif_grant()} | {unsupported, [atom()]}.
grant(none) ->
    {ok, none};
grant(all) ->
    {ok, all};
grant(Map) when is_map(Map) ->
    case maps:keys(maps:without([connect, listen, resolve, tcp, udp], Map)) of
        [] ->
            Rules =
                rules(0, maps:get(connect, Map, [])) ++ rules(1, maps:get(listen, Map, [])),
            Resolve = resolve(maps:get(resolve, Map, deny)),
            Tcp = transport(tcp, maps:get(tcp, Map, true)),
            Udp = transport(udp, maps:get(udp, Map, true)),
            case Rules =:= [] andalso not Resolve of
                %% grants nothing: the same as no grant at all
                true ->
                    {ok, none};
                false ->
                    {ok, {rules, Tcp, Udp, Resolve, Rules}}
            end;
        Keys ->
            case Keys -- [max_sockets, timeout] of
                [] -> {unsupported, Keys};
                _ -> bad(Map)
            end
    end;
grant(Other) ->
    bad(Other).

-spec bad(term()) -> no_return().
bad(Term) -> erlang:error({bad_net_grant, Term}).

resolve(allow) -> true;
resolve(deny) -> false;
resolve(Other) -> bad({resolve, Other}).

transport(_, Flag) when is_boolean(Flag) -> Flag;
transport(Protocol, Other) -> bad({Protocol, Other}).

rules(Listen, List) when is_list(List) -> [rule(Listen, Rule) || Rule <- List];
rules(_, Other) -> bad(Other).

rule(Listen, {Protocol, Address, Ports}) when Protocol =:= tcp; Protocol =:= udp ->
    {Bytes, Prefix} = cidr(Address),
    {First, Last} = ports(Ports),
    Udp =
        case Protocol of
            udp -> 1;
            tcp -> 0
        end,
    {Udp, Listen, Bytes, Prefix, First, Last};
rule(_, Other) ->
    bad(Other).

ports(any) ->
    {0, 65535};
ports(Port) when is_integer(Port), Port >= 0, Port =< 65535 ->
    {Port, Port};
ports({Low, High}) when
    is_integer(Low), is_integer(High), Low >= 0, Low =< High, High =< 65535
->
    {Low, High};
ports(Other) ->
    bad({port, Other}).

%% An address tuple, or its text with an optional prefix length.
cidr(Text) when is_binary(Text) ->
    case binary:split(Text, ~"/") of
        [Address] -> host(parse(Address));
        [Address, Length] -> network(parse(Address), integer(Length, Text), Text)
    end;
cidr(Address) when tuple_size(Address) =:= 4; tuple_size(Address) =:= 8 ->
    case inet:is_ip_address(Address) of
        true -> host(Address);
        false -> bad(Address)
    end;
cidr(Other) ->
    bad(Other).

parse(Text) ->
    case inet:parse_address(binary_to_list(Text)) of
        {ok, Address} -> Address;
        {error, _} -> bad(Text)
    end.

integer(Text, Written) ->
    try
        binary_to_integer(Text)
    catch
        error:badarg -> bad(Written)
    end.

%% No prefix length is one host.
host(Address) ->
    Bytes = bytes(unmapped(Address)),
    {Bytes, bit_size(Bytes)}.

%% The prefix length is in the notation the address was written in, so an
%% IPv4-mapped base loses its 96 mapping bits with them. A shorter one spans
%% mapped and unmapped addresses at once, which means nothing.
network(Address, Bits, Written) ->
    Bytes = bytes(Address),
    case unmapped(Address) of
        Address when Bits >= 0, Bits =< bit_size(Bytes) ->
            {Bytes, Bits};
        V4 when V4 =/= Address, Bits >= 96, Bits =< 128 ->
            {bytes(V4), Bits - 96};
        _ ->
            bad(Written)
    end.

%% ::ffff:a.b.c.d reaches the host a.b.c.d.
unmapped({0, 0, 0, 0, 0, 16#ffff, X, Y}) ->
    {X bsr 8, X band 16#ff, Y bsr 8, Y band 16#ff};
unmapped(Address) ->
    Address.

bytes({A, B, C, D}) ->
    <<A, B, C, D>>;
bytes({A, B, C, D, E, F, G, H}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>.
