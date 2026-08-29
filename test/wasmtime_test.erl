%% Shared by the wasmtime_*_SUITE modules: compiling test modules, the
%% hand-assembled binaries, and the capability checks that skip a suite or
%% group on a build without a compiler, WAT or WASI.
-module(wasmtime_test).
-include_lib("stdlib/include/assert.hrl").

-export([needs/2]).
-export([
    compile/1,
    instance/1, instance/2,
    table_wat/0,
    wasi_argv_wat/0,
    host_wat/0,
    handler/1,
    handler_loop/2,
    async_wat/0,
    async_inst/0,
    stdio_wat/0,
    fuel_wat/0,
    add_wat/0,
    add_binary/0,
    simd_binary/0,
    threads_binary/0,
    channel_wat/0,
    channel_inst/0, channel_inst/1,
    collect/2, collect/3,
    refs_wat/0,
    refs_inst/0, refs_inst/1,
    gc_wat/0
]).

%% Config, or a skip when the build lacks one of the capabilities.
needs(Caps, Config) ->
    F = wasmtime:features(),
    case [C || C <- Caps, not maps:get(C, F, false)] of
        [] -> Config;
        Missing -> {skip, lists:flatten(io_lib:format("needs a build with ~p", [Missing]))}
    end.

compile(Wat) ->
    {ok, Mod} = wasmtime:compile({wat, Wat}),
    Mod.

instance(Wat) -> instance(Wat, #{}).
instance(Wat, Opts) ->
    {ok, Inst} = wasmtime:instantiate(compile(Wat), Opts),
    Inst.

%% ---------------------------------------------------------------- module

table_wat() ->
    ~"""
    (module
      (type $i (func (result i32)))
      (type $f (func (result f64)))
      (table 4 funcref)
      (func $one (type $i) i32.const 1)
      (elem (i32.const 0) $one)
      (func (export "call") (param i32) (result i32)
        local.get 0 call_indirect (type $i))
      (func (export "call_f") (param i32) (result f64)
        local.get 0 call_indirect (type $f)))
    """.

%% Writes argv and environ, one entry per line, to stdout.
wasi_argv_wat() ->
    ~"""
    (module
      (import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes (param i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "args_get" (func $args_get (param i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "environ_sizes_get" (func $env_sizes (param i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "environ_get" (func $env_get (param i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "path_open"
        (func $path_open (param i32 i32 i32 i32 i32 i64 i64 i32 i32) (result i32)))
      (memory (export "memory") 1)
      (data (i32.const 4000) "\n")
      (data (i32.const 4010) "new.txt")
      ;; write NUL-terminated string at $ptr to $fd, then a newline
      (func $puts (param $fd i32) (param $ptr i32) (local $len i32)
        (block (loop
          (br_if 1 (i32.eqz (i32.load8_u (i32.add (local.get $ptr) (local.get $len)))))
          (local.set $len (i32.add (local.get $len) (i32.const 1)))
          (br 0)))
        (i32.store (i32.const 0) (local.get $ptr))
        (i32.store (i32.const 4) (local.get $len))
        (drop (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8)))
        (i32.store (i32.const 0) (i32.const 4000))
        (i32.store (i32.const 4) (i32.const 1))
        (drop (call $fd_write (local.get $fd) (i32.const 0) (i32.const 1) (i32.const 8))))
      ;; dump a (count, ptrs, buf) list obtained through $sizes/$get
      (func (export "args") (local $i i32) (local $n i32)
        (drop (call $args_sizes (i32.const 16) (i32.const 20)))
        (local.set $n (i32.load (i32.const 16)))
        (drop (call $args_get (i32.const 1000) (i32.const 2000)))
        (block (loop
          (br_if 1 (i32.ge_u (local.get $i) (local.get $n)))
          (call $puts (i32.const 1) (i32.load (i32.add (i32.const 1000) (i32.mul (local.get $i) (i32.const 4)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br 0))))
      (func (export "env") (local $i i32) (local $n i32)
        (drop (call $env_sizes (i32.const 16) (i32.const 20)))
        (local.set $n (i32.load (i32.const 16)))
        (drop (call $env_get (i32.const 1000) (i32.const 2000)))
        (block (loop
          (br_if 1 (i32.ge_u (local.get $i) (local.get $n)))
          (call $puts (i32.const 1) (i32.load (i32.add (i32.const 1000) (i32.mul (local.get $i) (i32.const 4)))))
          (local.set $i (i32.add (local.get $i) (i32.const 1)))
          (br 0))))
      ;; copy up to 64 bytes of stdin to stderr, return bytes read
      (func (export "cat") (result i32)
        (i32.store (i32.const 0) (i32.const 3000))
        (i32.store (i32.const 4) (i32.const 64))
        (drop (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 8)))
        (i32.store (i32.const 4) (i32.load (i32.const 8)))
        (drop (call $fd_write (i32.const 2) (i32.const 0) (i32.const 1) (i32.const 12)))
        (i32.load (i32.const 8)))
      ;; create "new.txt" in preopen fd 3 with O_CREAT; returns errno
      (func (export "create") (result i32)
        (call $path_open (i32.const 3) (i32.const 0) (i32.const 4010) (i32.const 7)
                         (i32.const 1) (i64.const 0x40) (i64.const 0) (i32.const 0) (i32.const 64))))
    """.

host_wat() ->
    ~"""
    (module
      (import "env" "twice" (func $twice (param i32) (result i32)))
      (func (export "run") (param i32) (result i32) local.get 0 call $twice))
    """.

%% A handler process: serves host calls for Inst until told to stop.
handler(Parent) ->
    receive
        {inst, Inst} -> handler_loop(Parent, Inst)
    end.

handler_loop(Parent, Inst) ->
    receive
        stop ->
            ok;
        Msg ->
            case wasmtime:handle_host_call(Inst, Msg) of
                ok -> Parent ! {served, self()};
                ignore -> Parent ! {ignored, Msg}
            end,
            handler_loop(Parent, Inst)
    end.

async_wat() ->
    ~"""
    (module
      (import "env" "twice" (func $twice (param i32) (result i32)))
      (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add)
      (func (export "loop") (loop br 0))
      (func (export "run") (param i32) (result i32) local.get 0 call $twice))
    """.

async_inst() ->
    instance(async_wat(), #{imports => #{{~"env", ~"twice"} => fun(_, [X]) -> {ok, [X * 2]} end}}).

stdio_wat() ->
    ~"""
    (module
      (import "wasi_snapshot_preview1" "fd_read" (func $fd_read (param i32 i32 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes (param i32 i32) (result i32)))
      (import "wasi_snapshot_preview1" "environ_sizes_get" (func $env_sizes (param i32 i32) (result i32)))
      (memory (export "memory") 1)
      ;; copy stdin to stdout (up to 1000 bytes), write "err" to stderr,
      ;; return the byte count
      (func (export "cat") (result i32)
        (i32.store (i32.const 0) (i32.const 3000))
        (i32.store (i32.const 4) (i32.const 1000))
        (drop (call $fd_read (i32.const 0) (i32.const 0) (i32.const 1) (i32.const 8)))
        (i32.store (i32.const 4) (i32.load (i32.const 8)))
        (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 12)))
        (i32.store (i32.const 16) (i32.const 40))
        (i32.store (i32.const 20) (i32.const 3))
        (drop (call $fd_write (i32.const 2) (i32.const 16) (i32.const 1) (i32.const 12)))
        (i32.load (i32.const 8)))
      (data (i32.const 40) "err")
      ;; write N times "0123456789" to stdout
      (func (export "spam") (param $n i32)
        (i32.store (i32.const 0) (i32.const 60))
        (i32.store (i32.const 4) (i32.const 10))
        (block (loop
          (br_if 1 (i32.eqz (local.get $n)))
          (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 1) (i32.const 12)))
          (local.set $n (i32.sub (local.get $n) (i32.const 1)))
          (br 0))))
      (data (i32.const 60) "0123456789")
      (func (export "argc") (result i32)
        (drop (call $args_sizes (i32.const 100) (i32.const 104))) (i32.load (i32.const 100)))
      (func (export "envc") (result i32)
        (drop (call $env_sizes (i32.const 100) (i32.const 104))) (i32.load (i32.const 100))))
    """.

fuel_wat() ->
    ~"""
    (module
      (func (export "spin") (param $n i32)
        (block (loop
          (br_if 1 (i32.eqz (local.get $n)))
          (local.set $n (i32.sub (local.get $n) (i32.const 1)))
          (br 0))))
      (func (export "loop") (loop br 0))
      (func (export "one") (result i32) i32.const 1))
    """.

add_wat() ->
    ~"(module (func (export \"add\") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))".

%% (module (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
add_binary() ->
    {ok, Mod} = wasmtime:compile({wat, add_wat()}),
    _ = Mod,
    <<0, "asm", 1, 0, 0, 0, 1, 7, 1, 16#60, 2, 16#7f, 16#7f, 1, 16#7f, 3, 2, 1, 0, 7, 7, 1, 3,
        "add", 0, 0, 10, 9, 1, 7, 0, 16#20, 0, 16#20, 1, 16#6a, 16#0b>>.

%% (module (func (export "id") (param v128) (result v128) local.get 0))
simd_binary() ->
    <<0, "asm", 1, 0, 0, 0, 1, 6, 1, 16#60, 1, 16#7b, 1, 16#7b, 3, 2, 1, 0, 7, 6, 1, 2, "id", 0, 0,
        10, 6, 1, 4, 0, 16#20, 0, 16#0b>>.

%% (module (memory 1 1 shared))
threads_binary() ->
    <<0, "asm", 1, 0, 0, 0, 5, 4, 1, 3, 1, 1>>.

%% --------------------------------------------------------------- streams

channel_wat() ->
    ~"""
    (module
      (import "erlang" "send" (func $send (param i32 i32)))
      (import "erlang" "recv" (func $recv (param i32 i32) (result i32)))
      (memory (export "memory") 1)
      ;; echo every message back until the input is closed; count them
      (func (export "echo") (result i32) (local $n i32) (local $count i32)
        (block (loop
          (local.set $n (call $recv (i32.const 0) (i32.const 1024)))
          (br_if 1 (i32.lt_s (local.get $n) (i32.const 0)))
          (call $send (i32.const 0) (local.get $n))
          (local.set $count (i32.add (local.get $count) (i32.const 1)))
          (br 0)))
        (local.get $count))
      (func (export "recv_into") (param i32) (result i32)
        (call $recv (i32.const 0) (local.get 0)))
      (func (export "send_at") (param i32 i32) (call $send (local.get 0) (local.get 1))))
    """.

channel_inst() -> channel_inst(#{}).
channel_inst(Opts) -> instance(channel_wat(), Opts).

collect(Kind, N) -> collect(Kind, N, []).
collect(_, 0, Acc) ->
    lists:reverse(Acc);
collect(Kind, N, Acc) ->
    receive
        {wasmtime_stream, _, Kind, Bytes} -> collect(Kind, N - 1, [Bytes | Acc])
    after 2000 -> error({missing_stream_message, Kind, N})
    end.

refs_wat() ->
    ~"""
    (module
      (type $bin (func (param i32 i32) (result i32)))
      (import "env" "ext_id" (func $ext_id (param externref) (result externref)))
      (import "env" "take_fn" (func $take_fn (param funcref) (result i32)))
      (global $g (export "g") (mut externref) (ref.null extern))
      (table $t (export "t") 4 funcref)
      (table $e (export "e") 4 externref)
      (elem (i32.const 0) $add $twice)
      (func $add (export "add") (param i32 i32) (result i32)
        local.get 0 local.get 1 i32.add)
      (func $twice (param i32 i32) (result i32) local.get 0 i32.const 2 i32.mul)
      (func (export "id_ext") (param externref) (result externref) local.get 0)
      (func (export "set_g") (param externref) local.get 0 global.set $g)
      (func (export "via_host") (param externref) (result externref) local.get 0 call $ext_id)
      (func (export "host_fn") (result i32) ref.func $add call $take_fn)
      (func (export "keep") (param externref) (table.set $e (i32.const 0) (local.get 0)))
      (func (export "is_null") (param externref) (result i32) local.get 0 ref.is_null)
      (func (export "nonnull") (param (ref func)) (result i32) i32.const 1)
      (func (export "call_slot") (param i32 i32 i32) (result i32)
        local.get 1 local.get 2 local.get 0 call_indirect (type $bin))
      (func (export "loop") (loop br 0)))
    """.

refs_inst() -> refs_inst(#{}).
refs_inst(Imports) ->
    Defaults = #{
        {~"env", ~"ext_id"} => fun(_, [X]) -> {ok, [X]} end,
        {~"env", ~"take_fn"} => fun(_, [_]) -> {ok, [0]} end
    },
    instance(refs_wat(), #{imports => maps:merge(Defaults, Imports)}).

gc_wat() ->
    ~"""
    (module
      (type $point (struct (field (mut i32)) (field (mut f64)) (field (mut i8))))
      (type $arr (array (mut i32)))
      (func (export "mk_point") (param i32 f64) (result anyref)
        (struct.new $point (local.get 0) (local.get 1) (i32.const 7)))
      (func (export "px") (param anyref) (result i32)
        (struct.get $point 0 (ref.cast (ref $point) (local.get 0))))
      (func (export "mk_arr") (param i32) (result anyref)
        (array.new $arr (local.get 0) (i32.const 5)))
      (func (export "a0") (param anyref) (result i32)
        (array.get $arr (ref.cast (ref $arr) (local.get 0)) (i32.const 0)))
      (func (export "id_any") (param anyref) (result anyref) local.get 0)
      (func (export "i31v") (param anyref) (result i32)
        (i31.get_s (ref.cast (ref i31) (local.get 0))))
      (func (export "want_arr") (param (ref array)) (result i32) i32.const 1))
    """.
