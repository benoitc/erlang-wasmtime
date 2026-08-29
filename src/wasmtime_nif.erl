-module(wasmtime_nif).
-moduledoc false.

-export([
    compile/2,
    module_imports/1,
    module_exports/1,
    serialize/1,
    deserialize/1,
    instantiate/4,
    call/4,
    host_reply/3,
    interrupt/1,
    cancel/2,
    read_memory/4,
    write_memory/4,
    memory_size/2,
    read_output/1,
    features/0,
    version/0
]).
-nifs([
    compile/2,
    module_imports/1,
    module_exports/1,
    serialize/1,
    deserialize/1,
    instantiate/4,
    call/4,
    host_reply/3,
    interrupt/1,
    cancel/2,
    read_memory/4,
    write_memory/4,
    memory_size/2,
    read_output/1,
    features/0,
    version/0
]).
-on_load(init/0).

init() ->
    Priv =
        case code:priv_dir(erlang_wasmtime) of
            {error, bad_name} ->
                filename:join(filename:dirname(filename:dirname(code:which(?MODULE))), "priv");
            Dir ->
                Dir
        end,
    erlang:load_nif(filename:join(Priv, "wasmtime_nif"), 0).

compile(_Bin, _IsWat) -> erlang:nif_error(not_loaded).
module_imports(_Mod) -> erlang:nif_error(not_loaded).
module_exports(_Mod) -> erlang:nif_error(not_loaded).
serialize(_Mod) -> erlang:nif_error(not_loaded).
deserialize(_Bin) -> erlang:nif_error(not_loaded).
instantiate(_Mod, _Opts, _Ref, _Id) -> erlang:nif_error(not_loaded).
call(_Handle, _Name, _Args, _Id) -> erlang:nif_error(not_loaded).
host_reply(_Handle, _Id, _Reply) -> erlang:nif_error(not_loaded).
interrupt(_Handle) -> erlang:nif_error(not_loaded).
cancel(_Handle, _Id) -> erlang:nif_error(not_loaded).
read_memory(_Handle, _Name, _Ptr, _Len) -> erlang:nif_error(not_loaded).
write_memory(_Handle, _Name, _Ptr, _Bin) -> erlang:nif_error(not_loaded).
memory_size(_Handle, _Name) -> erlang:nif_error(not_loaded).
read_output(_Handle) -> erlang:nif_error(not_loaded).
features() -> erlang:nif_error(not_loaded).
version() -> erlang:nif_error(not_loaded).
