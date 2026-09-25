%% Pre-initialization: run a module's init exports once, then write a new
%% module whose memories and globals start in the state they left. The
%% algorithm is Wizer's (Wasmtime's crates/wizer), in three passes:
%%
%%   instrument  export every defined memory, mutable global and table
%%               under a reserved name, so the state can be read back;
%%   snapshot    instantiate that, run the init calls, read the memories'
%%               non-zero ranges and the globals' bits (c_src/nif_preinit.c);
%%   rewrite     the original module with the memories' minimum sizes and
%%               the globals' initial values set from the snapshot, the old
%%               active data segments emptied (they were applied), the
%%               snapshot appended as active segments, the start section
%%               and the named exports removed.
%%
%% Wizer refuses modules whose code could change a table or drop a segment
%% by scanning every instruction. Here the tables are compared before and
%% after the init calls instead; docs/preinit.md says what that leaves out.
-module(wasmtime_preinit).
-moduledoc false.

-export([run/3]).

-define(PREFIX, "__wasmtime_preinit_").

%% Section ids, and the order non-custom sections must appear in.
-define(CUSTOM, 0).
-define(TYPE, 1).
-define(IMPORT, 2).
-define(TABLE, 4).
-define(MEMORY, 5).
-define(GLOBAL, 6).
-define(EXPORT, 7).
-define(START, 8).
-define(DATA, 11).
-define(DATACOUNT, 12).
-define(ORDER, [1, 2, 3, 4, 5, 13, 6, 7, 8, 9, 12, 10, 11]).

-spec run(binary(), map(), [wasmtime:preinit_call()] | fun((wasmtime:instance()) -> term())) ->
    {ok, binary()} | wasmtime:error().
run(Wasm, Opts, Init) when is_binary(Wasm), is_map(Opts) ->
    CompileOpts = maps:get(compile, Opts, #{}),
    InstOpts = maps:without([compile, remove_exports], Opts),
    Remove = [iolist_to_binary(N) || N <- maps:get(remove_exports, Opts, [])],
    try
        M = parse(Wasm),
        check(M),
        {Instrumented, Names} = instrument(M),
        maybe
            {ok, Mod} ?= wasmtime:compile(Instrumented, CompileOpts),
            {ok, Inst} ?= wasmtime:instantiate(Mod, InstOpts),
            {ok, Before} ?= tables(Inst, Names),
            ok ?= init(Inst, Init),
            {ok, Before} ?= tables(Inst, Names),
            {ok, Snapshot} ?= snapshot(Inst, Names),
            Out = rewrite(M, Snapshot, Remove ++ initialize(Init)),
            ok ?= wasmtime:validate(Out, maps:with([proposals], CompileOpts)),
            {ok, Out}
        else
            {ok, _Changed} -> preinit_error(table_changed, "an init call changed a table");
            {error, _} = Error -> Error;
            Other -> preinit_error(init, io_lib:format("the init fun returned ~0p", [Other]))
        end
    catch
        throw:{preinit, Kind, Msg} -> preinit_error(Kind, Msg)
    end.

preinit_error(Kind, Msg) ->
    {error, #{class => preinit, kind => Kind, message => iolist_to_binary(Msg)}}.

-spec fail(atom(), iodata()) -> no_return().
fail(Kind, Msg) -> throw({preinit, Kind, Msg}).

%% A WASI reactor's `_initialize` sets up its C library: once run it is in
%% the image, and running it again would redo that over live state.
initialize(Init) when is_list(Init) ->
    [~"_initialize" || C <- Init, call_name(C) =:= ~"_initialize"];
initialize(_) ->
    [].

call_name({Name, _Args}) -> iolist_to_binary(Name);
call_name(Name) -> iolist_to_binary(Name).

init(Inst, Fun) when is_function(Fun, 1) ->
    case Fun(Inst) of
        ok -> ok;
        {ok, _} -> ok;
        Other -> Other
    end;
init(Inst, Calls) when is_list(Calls) ->
    lists:foldl(
        fun
            (Call, ok) ->
                Args =
                    case Call of
                        {_, A} -> A;
                        _ -> []
                    end,
                case wasmtime:call(Inst, call_name(Call), Args) of
                    {ok, _} -> ok;
                    {error, _} = Error -> Error
                end;
            (_, Error) ->
                Error
        end,
        ok,
        Calls
    ).

%% ------------------------------------------------------------------ parse

%% #{sections => [{Id, Payload}], tables => N, memories => [MemType],
%%   globals => [{Type, Mutable, Init}], exports => [{Name, Kind, Index}]}
parse(<<0, "asm", 1, 0, 0, 0, Rest/binary>>) ->
    Sections = sections(Rest, []),
    lists:foldl(
        fun section_info/2,
        #{
            sections => Sections,
            tables => 0,
            memories => [],
            globals => [],
            exports => [],
            imports => []
        },
        Sections
    );
parse(<<0, "asm", _/binary>>) ->
    fail(unsupported, "only core modules can be pre-initialized, not components");
parse(_) ->
    fail(malformed, "not a WebAssembly binary").

sections(<<>>, Acc) ->
    lists:reverse(Acc);
sections(<<Id, Rest0/binary>>, Acc) ->
    {Size, Rest1} = uleb(Rest0),
    case Rest1 of
        <<Payload:Size/binary, Rest/binary>> -> sections(Rest, [{Id, Payload} | Acc]);
        _ -> fail(malformed, "a section runs past the end of the module")
    end.

section_info({?TYPE, P}, M) ->
    {N, Rest} = uleb(P),
    types(N, Rest, 0),
    M;
section_info({?IMPORT, P}, M) ->
    M#{imports := imports(P)};
section_info({?TABLE, P}, M) ->
    {N, _} = uleb(P),
    M#{tables := N};
section_info({?MEMORY, P}, M) ->
    M#{memories := items(P, fun memtype/1)};
section_info({?GLOBAL, P}, M) ->
    M#{globals := items(P, fun global/1)};
section_info({?EXPORT, P}, M) ->
    M#{exports := items(P, fun export/1)};
section_info(_, M) ->
    M.

%% A snapshot has no GC heap: only function types may be declared.
types(N, _, N) ->
    ok;
types(N, <<16#60, Rest0/binary>>, I) ->
    {_, Rest1} = valtypes(Rest0),
    {_, Rest} = valtypes(Rest1),
    types(N, Rest, I + 1);
types(_, _, _) ->
    fail(unsupported_type, "GC types (structs, arrays, recursion groups) cannot be captured").

valtypes(Bin) ->
    {N, Rest} = uleb(Bin),
    lists:foldl(
        fun(_, {Acc, R}) ->
            {T, R1} = valtype(R),
            {[T | Acc], R1}
        end,
        {[], Rest},
        lists:seq(1, N)
    ).

imports(P) ->
    items(P, fun(B0) ->
        {Module, B1} = name(B0),
        {Name, B2} = name(B1),
        case B2 of
            <<0, B3/binary>> ->
                {_, B} = uleb(B3),
                {{Module, Name, func}, B};
            <<4, 0, B3/binary>> ->
                {_, B} = uleb(B3),
                {{Module, Name, tag}, B};
            <<K, _/binary>> when K >= 1, K =< 3 ->
                fail(
                    unsupported_import,
                    [
                        "imported ",
                        element(K, {"tables", "memories", "globals"}),
                        " cannot be captured: ",
                        Module,
                        ".",
                        Name
                    ]
                );
            _ ->
                fail(malformed, "unknown import kind")
        end
    end).

%% {Flags, Min, Max | undefined, PageLog2 | undefined}
memtype(<<Flags, B0/binary>>) ->
    Flags band 2 =:= 0 orelse fail(unsupported, "a shared memory cannot be captured"),
    Flags band 16#F0 =:= 0 orelse fail(malformed, "unknown memory flags"),
    {Min, B1} = uleb(B0),
    {Max, B2} =
        case Flags band 1 of
            1 -> uleb(B1);
            0 -> {undefined, B1}
        end,
    {Page, B} =
        case Flags band 8 of
            8 -> uleb(B2);
            0 -> {undefined, B2}
        end,
    {{Flags, Min, Max, Page}, B}.

global(B0) ->
    {Type, B1} = valtype(B0),
    <<Mut, B2/binary>> = B1,
    {Init, B} = const_expr(B2),
    case {Type, Mut} of
        {{ref, _}, 1} -> fail(unsupported_type, "a mutable reference global cannot be captured");
        _ -> {{Type, Mut =:= 1, Init}, B}
    end.

export(B0) ->
    {Name, <<Kind, B1/binary>>} = name(B0),
    {Idx, B} = uleb(B1),
    {{Name, Kind, Idx}, B}.

%% {num, Byte} for numbers and v128, {ref, Bytes} for references.
valtype(<<T, B/binary>>) when T >= 16#7B, T =< 16#7F -> {{num, T}, B};
valtype(<<T, B/binary>>) when T >= 16#69, T =< 16#74 -> {{ref, <<T>>}, B};
valtype(<<T, B0/binary>>) when T =:= 16#63; T =:= 16#64 ->
    {_, B} = sleb(B0),
    Len = byte_size(B0) - byte_size(B),
    {{ref, <<T, (binary:part(B0, 0, Len))/binary>>}, B};
valtype(_) ->
    fail(malformed, "unknown value type").

%% A constant expression, returned as its bytes including the final `end`.
const_expr(Bin) -> const_expr(Bin, Bin).
const_expr(Start, <<16#0B, B/binary>>) ->
    {binary:part(Start, 0, byte_size(Start) - byte_size(B)), B};
const_expr(Start, <<Op, B0/binary>>) when Op =:= 16#41; Op =:= 16#42 ->
    const_expr(Start, skip_sleb(B0));
const_expr(Start, <<16#43, _:4/binary, B/binary>>) ->
    const_expr(Start, B);
const_expr(Start, <<16#44, _:8/binary, B/binary>>) ->
    const_expr(Start, B);
const_expr(Start, <<Op, B0/binary>>) when Op =:= 16#23; Op =:= 16#D2 ->
    const_expr(Start, skip_uleb(B0));
const_expr(Start, <<16#D0, B0/binary>>) ->
    const_expr(Start, skip_sleb(B0));
const_expr(Start, <<Op, B/binary>>) when
    Op =:= 16#6A; Op =:= 16#6B; Op =:= 16#6C; Op =:= 16#7C; Op =:= 16#7D; Op =:= 16#7E
->
    const_expr(Start, B);
const_expr(Start, <<16#FD, 12, _:16/binary, B/binary>>) ->
    const_expr(Start, B);
const_expr(Start, <<16#FB, Sub, B/binary>>) when Sub >= 16#1A, Sub =< 16#1C ->
    const_expr(Start, B);
const_expr(_, _) ->
    fail(
        unsupported, "a constant expression uses an instruction this pre-initializer does not read"
    ).

items(P, Fun) ->
    {N, Rest} = uleb(P),
    {Items, _} = lists:foldl(
        fun(_, {Acc, R}) ->
            {Item, R1} = Fun(R),
            {[Item | Acc], R1}
        end,
        {[], Rest},
        lists:seq(1, N)
    ),
    lists:reverse(Items).

name(B0) ->
    {Len, B1} = uleb(B0),
    case B1 of
        <<Name:Len/binary, B/binary>> -> {Name, B};
        _ -> fail(malformed, "a name runs past the end of its section")
    end.

check(#{exports := Exports}) ->
    [
        fail(unsupported, ["the export name ", N, " is reserved"])
     || {N, _, _} <- Exports,
        binary:longest_common_prefix([N, <<?PREFIX>>]) =:= byte_size(<<?PREFIX>>)
    ],
    ok.

%% -------------------------------------------------------------- instrument

%% The module with its state exported, and the names used: #{memories =>
%% [Name], globals => [{Index, Name}], tables => [Name]}. Nothing is
%% imported (check/1), so defined indices start at 0.
instrument(#{sections := Sections, memories := Mems, globals := Globals, tables := NTables} = M) ->
    MemExports = [{export_name("memory", I), 2, I} || I <- seq(length(Mems))],
    GlobalExports = [
        {export_name("global", I), 3, I}
     || {I, {_, true, _}} <- lists:zip(seq(length(Globals)), Globals)
    ],
    TableExports = [{export_name("table", I), 1, I} || I <- seq(NTables)],
    Exports = maps:get(exports, M) ++ MemExports ++ GlobalExports ++ TableExports,
    Section = {?EXPORT, encode_vec([encode_export(E) || E <- Exports])},
    Names = #{
        memories => [N || {N, _, _} <- MemExports],
        globals => [{I, N} || {N, _, I} <- GlobalExports],
        tables => [N || {N, _, _} <- TableExports]
    },
    {encode(replace_or_insert(Section, Sections)), Names}.

export_name(What, I) -> iolist_to_binary([?PREFIX, What, "_", integer_to_list(I)]).

seq(0) -> [];
seq(N) -> lists:seq(0, N - 1).

%% ---------------------------------------------------------------- snapshot

tables(Inst, #{tables := Names}) ->
    lists:foldl(
        fun
            (N, {ok, Acc}) ->
                case wasmtime_nif:preinit_table(wasmtime:handle(Inst), N) of
                    {ok, F} -> {ok, [F | Acc]};
                    {error, _} = E -> E
                end;
            (_, E) ->
                E
        end,
        {ok, []},
        Names
    ).

snapshot(Inst, #{memories := Mems, globals := Globals}) ->
    H = wasmtime:handle(Inst),
    maybe
        {ok, MemSnaps} ?= collect([fun() -> memory(H, N) end || N <- Mems]),
        {ok, GlobalSnaps} ?= collect([fun() -> global(H, I, N) end || {I, N} <- Globals]),
        {ok, #{memories => MemSnaps, globals => maps:from_list(GlobalSnaps)}}
    end.

memory(H, Name) ->
    case wasmtime_nif:preinit_memory(H, Name) of
        {ok, Pages, Segments} -> {ok, {Pages, Segments}};
        {error, _} = E -> E
    end.

global(H, I, Name) ->
    case wasmtime_nif:preinit_global(H, Name) of
        {ok, Kind, Bits} -> {ok, {I, {Kind, Bits}}};
        {error, _} = E -> E
    end.

collect(Funs) ->
    lists:foldl(
        fun
            (F, {ok, Acc}) ->
                case F() of
                    {ok, V} -> {ok, Acc ++ [V]};
                    {error, _} = E -> E
                end;
            (_, E) ->
                E
        end,
        {ok, []},
        Funs
    ).

%% ----------------------------------------------------------------- rewrite

rewrite(#{sections := Sections} = M, #{memories := MemSnaps} = Snap, Remove) ->
    Segments = [
        {MemIdx, Is64, Offset, Bytes}
     || {MemIdx, {{Flags, _, _, _}, {_, Segs}}} <- lists:zip(
            seq(length(MemSnaps)), lists:zip(maps:get(memories, M), MemSnaps)
        ),
        Is64 <- [Flags band 4 =:= 4],
        {Offset, Bytes} <- dense(Segs)
    ],
    Out0 = lists:filtermap(fun(S) -> rewrite_section(S, M, Snap, Segments, Remove) end, Sections),
    Out1 =
        case lists:keymember(?DATA, 1, Out0) of
            true -> Out0;
            false -> insert_data({?DATA, encode_vec([encode_segment(S) || S <- Segments])}, Out0)
        end,
    encode(Out1).

rewrite_section({?MEMORY, _}, #{memories := Mems}, #{memories := Snaps}, _, _) ->
    {true,
        {?MEMORY,
            encode_vec([
                encode_memtype(Flags, Pages, Max, Page)
             || {{Flags, _, Max, Page}, {Pages, _}} <- lists:zip(Mems, Snaps)
            ])}};
rewrite_section({?GLOBAL, _}, #{globals := Globals}, #{globals := Values}, _, _) ->
    {true,
        {?GLOBAL,
            encode_vec([
                encode_global(G, maps:get(I, Values, undefined))
             || {I, G} <- lists:zip(seq(length(Globals)), Globals)
            ])}};
rewrite_section({?EXPORT, _}, #{exports := Exports}, _, _, Remove) ->
    {true,
        {?EXPORT,
            encode_vec([encode_export(E) || {N, _, _} = E <- Exports, not lists:member(N, Remove)])}};
rewrite_section({?START, _}, _, _, _, _) ->
    false;
rewrite_section({?DATACOUNT, P}, _, _, Segments, _) ->
    {N, _} = uleb(P),
    {true, {?DATACOUNT, uleb_enc(N + length(Segments))}};
rewrite_section({?DATA, P}, _, _, Segments, _) ->
    %% Active segments were applied when the snapshot was taken; they stay as
    %% empty passive segments so segment indices do not move. Passive ones
    %% are kept for memory.init.
    Old = items(P, fun data_segment/1),
    {true, {?DATA, encode_vec(Old ++ [encode_segment(S) || S <- Segments])}};
rewrite_section(S, _, _, _, _) ->
    {true, S}.

%% Wasmtime maps a memory's initial image copy-on-write only when the
%% segments cover at least half of the span from the first to the last
%% initialized byte, or the span is under 16 MB (try_static_init in
%% wasmtime-environ; the C API cannot change that size). Otherwise it copies
%% every segment at each instantiation. A snapshot is mostly zeros, so the
%% smallest gaps are filled with zeros until the rule holds.
-define(ALWAYS_DENSE, 16 bsl 20).

dense([]) ->
    [];
dense(Segs) ->
    {First, _} = hd(Segs),
    {LastOff, LastBytes} = lists:last(Segs),
    Span = LastOff + byte_size(LastBytes) - First,
    Data = lists:sum([byte_size(B) || {_, B} <- Segs]),
    case Span < 2 * Data orelse Span < ?ALWAYS_DENSE of
        true -> Segs;
        false -> fill(Segs, Span div 2 + 1 - Data)
    end.

%% Merge across the smallest gaps until `Need` more bytes are covered.
fill(Segs, Need) ->
    Gaps = lists:sort(gaps(Segs, 0, [])),
    Merge = sets:from_list(take_gaps(Gaps, Need, []), [{version, 2}]),
    merge(Segs, 0, Merge).

gaps([{O1, B1}, {O2, _} = S2 | Rest], I, Acc) ->
    gaps([S2 | Rest], I + 1, [{O2 - O1 - byte_size(B1), I} | Acc]);
gaps(_, _, Acc) ->
    Acc.

take_gaps(_, Need, Acc) when Need =< 0 -> Acc;
take_gaps([{Size, I} | Rest], Need, Acc) -> take_gaps(Rest, Need - Size, [I | Acc]);
take_gaps([], _, Acc) -> Acc.

%% Gap I lies between segment I and I + 1.
merge([{O1, B1}, {O2, B2} | Rest], I, Merge) ->
    case sets:is_element(I, Merge) of
        true ->
            Zeros = O2 - O1 - byte_size(B1),
            merge([{O1, <<B1/binary, 0:(Zeros * 8), B2/binary>>} | Rest], I + 1, Merge);
        false ->
            [{O1, B1} | merge([{O2, B2} | Rest], I + 1, Merge)]
    end;
merge(Segs, _, _) ->
    Segs.

data_segment(<<0, B0/binary>>) ->
    {_, B1} = const_expr(B0),
    {_, B} = bytes(B1),
    {<<1, 0>>, B};
data_segment(<<1, B0/binary>>) ->
    {Bytes, B} = bytes(B0),
    {[1, uleb_enc(byte_size(Bytes)), Bytes], B};
data_segment(<<2, B0/binary>>) ->
    {_, B1} = uleb(B0),
    {_, B2} = const_expr(B1),
    {_, B} = bytes(B2),
    {<<1, 0>>, B};
data_segment(_) ->
    fail(malformed, "unknown data segment kind").

bytes(B0) ->
    {Len, B1} = uleb(B0),
    <<Bytes:Len/binary, B/binary>> = B1,
    {Bytes, B}.

encode_segment({MemIdx, Is64, Offset, Bytes}) ->
    Expr =
        case Is64 of
            true -> [16#42, sleb_enc(Offset), 16#0B];
            false -> [16#41, sleb_enc(signed32(Offset)), 16#0B]
        end,
    Head =
        case MemIdx of
            0 -> [0];
            _ -> [2, uleb_enc(MemIdx)]
        end,
    [Head, Expr, uleb_enc(byte_size(Bytes)), Bytes].

encode_memtype(Flags, Min, Max, Page) ->
    [
        Flags,
        uleb_enc(Min),
        case Max of
            undefined -> [];
            _ -> uleb_enc(Max)
        end,
        case Page of
            undefined -> [];
            _ -> uleb_enc(Page)
        end
    ].

encode_global({Type, false, Init}, undefined) ->
    [encode_valtype(Type), 0, Init];
encode_global({Type, true, _}, {Kind, Bits}) ->
    [encode_valtype(Type), 1, const_of(Kind, Bits), 16#0B].

const_of(i32, <<V:32/little-signed>>) -> [16#41, sleb_enc(V)];
const_of(i64, <<V:64/little-signed>>) -> [16#42, sleb_enc(V)];
const_of(f32, Bits) -> [16#43, Bits];
const_of(f64, Bits) -> [16#44, Bits];
const_of(v128, Bits) -> [16#FD, 12, Bits].

encode_valtype({num, T}) -> T;
encode_valtype({ref, Bytes}) -> Bytes.

encode_export({Name, Kind, Idx}) -> [uleb_enc(byte_size(Name)), Name, Kind, uleb_enc(Idx)].

signed32(V) when V >= 16#80000000 -> V - 16#100000000;
signed32(V) -> V.

%% --------------------------------------------------------------- sections

%% Some tools expect the name section last, so a new data section goes
%% before it; otherwise at the end, after the code section.
insert_data(Data, Sections) ->
    {Before, After} = lists:splitwith(fun(S) -> not is_name_section(S) end, Sections),
    Before ++ [Data | After].

is_name_section({?CUSTOM, P}) ->
    try name(P) of
        {~"name", _} -> true;
        _ -> false
    catch
        throw:_ -> false
    end;
is_name_section(_) ->
    false.

%% The section in place of the one with its id, or inserted before the
%% first section that must come after it.
replace_or_insert({Id, _} = New, Sections) ->
    case lists:keymember(Id, 1, Sections) of
        true ->
            lists:keyreplace(Id, 1, Sections, New);
        false ->
            Rank = rank(Id),
            {Before, After} = lists:splitwith(
                fun({I, _}) -> I =:= ?CUSTOM orelse rank(I) < Rank end, Sections
            ),
            Before ++ [New | After]
    end.

rank(Id) -> string:str(?ORDER, [Id]).

encode(Sections) ->
    iolist_to_binary([
        <<0, "asm", 1, 0, 0, 0>>
        | [
            [Id, uleb_enc(iolist_size(P)), P]
         || {Id, P} <- Sections
        ]
    ]).

encode_vec(Items) -> [uleb_enc(length(Items)) | Items].

%% ------------------------------------------------------------------ LEB128

uleb(Bin) -> uleb(Bin, 0, 0).
uleb(<<1:1, V:7, Rest/binary>>, Shift, Acc) when Shift < 64 ->
    uleb(Rest, Shift + 7, Acc bor (V bsl Shift));
uleb(<<0:1, V:7, Rest/binary>>, Shift, Acc) ->
    {Acc bor (V bsl Shift), Rest};
uleb(_, _, _) ->
    fail(malformed, "bad LEB128 integer").

sleb(Bin) -> sleb(Bin, 0, 0).
sleb(<<1:1, V:7, Rest/binary>>, Shift, Acc) when Shift < 64 ->
    sleb(Rest, Shift + 7, Acc bor (V bsl Shift));
sleb(<<0:1, V:7, Rest/binary>>, Shift, Acc) ->
    R = Acc bor (V bsl Shift),
    Bits = Shift + 7,
    case V band 16#40 of
        0 -> {R, Rest};
        _ -> {R - (1 bsl Bits), Rest}
    end;
sleb(_, _, _) ->
    fail(malformed, "bad LEB128 integer").

skip_uleb(B) -> element(2, uleb(B)).
skip_sleb(B) -> element(2, sleb(B)).

uleb_enc(V) when V < 16#80 -> <<V>>;
uleb_enc(V) -> <<1:1, (V band 16#7F):7, (uleb_enc(V bsr 7))/binary>>.

sleb_enc(V) ->
    B = V band 16#7F,
    Next = V bsr 7,
    case (Next =:= 0 andalso B band 16#40 =:= 0) orelse (Next =:= -1 andalso B band 16#40 =/= 0) of
        true -> <<B>>;
        false -> <<1:1, B:7, (sleb_enc(Next))/binary>>
    end.
