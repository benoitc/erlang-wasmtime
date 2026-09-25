# Pre-initialization

`preinit/3` runs a module's init exports once and gives you a new module
that starts in the state they left: Wizer's pre-initialization, done by the
runtime. Combined with the pooling allocator and a module mapped from its
file, a fresh instance of a started interpreter costs about 0.1 ms instead
of the 124 ms it takes CPython to start. You need it when every request must
run in a fresh instance (nothing leaks between requests) and the guest has an
expensive start: an interpreter, a large runtime, imports to load.

## Capture the started guest, once

```erlang
{ok, Wasm} = file:read_file("py_reactor.wasm"),
Opts = #{
    imports => Imports,
    wasi => #{args => [~"python"],
              dirs => [{"/", InitDir, read}, {"/lib", Lib, read}],
              clocks => monotonic}},
{ok, Pre} = wasmtime:preinit(Wasm, Opts, [~"_initialize", ~"init"]).
```

`Opts` are ordinary instantiate options: the init calls see these preopens,
environment and host functions. The calls run in order; a trap or error
refuses the snapshot and is returned as it is.

When the capture needs a check, pass a fun instead of a list. It gets the
instance and returns `ok` to take the snapshot:

```erlang
Init = fun(Inst) ->
    {ok, _} = wasmtime:call(Inst, ~"_initialize", []),
    {ok, [0]} = wasmtime:call(Inst, ~"init", []),
    {ok, [1]} = wasmtime:call(Inst, ~"ready", []),
    ok
end,
{ok, Pre} = wasmtime:preinit(Wasm, Opts, Init).
```

## Compile it for the pool and cache it

```erlang
Pool = #{allocator => pooling,
         pooling => #{instances => 256, max_memory => 256 bsl 20}},
{ok, Mod0} = wasmtime:compile(Pre, Pool),
{ok, Cwasm} = wasmtime:serialize(Mod0),
ok = file:write_file("py_reactor.cwasm", Cwasm).
```

Key the cache on what went into the capture: the module, the init calls and
anything the init read (for hornbeam, the deployed digest).

## Serve each request from a fresh instance

```erlang
{ok, Mod} = wasmtime:deserialize_file("py_reactor.cwasm", Pool),

handle(Mod, Opts) ->
    {ok, Inst} = wasmtime:instantiate(Mod, Opts),
    try wasmtime:call(Inst, ~"handle", [], #{timeout => 5000})
    after ok = wasmtime:destroy(Inst)
    end.
```

`destroy/1` frees the store at once, so the pool slot is free when it
returns; without it the slot is held until the handle is garbage collected.

## What it costs

hornbeam's CPython 3.14 reactor, Apple M4 Pro, macOS, one caller
(`scripts/bench-reactor.sh`, full tables in [throughput](throughput.md)):

| Step | Time |
|---|---|
| `preinit/3` (`_initialize`, `init`, one `handle`) | 580 ms, once |
| compile the 50 MB result | 390 ms, once |
| `deserialize_file/2` | 1.6 ms, at start |
| instantiate | 0.14 ms |
| `handle`: json work and one `hornbeam.call` | 1.20 ms |
| destroy | 0.07 ms |

A fresh instance with CPython started in it, without pre-initialization:
124 ms.

## How the memory image is shared

The snapshot becomes the module's data segments. Wasmtime turns them into
one memory image and maps it into each instance copy-on-write: pages the
guest only reads stay shared, a page it writes is copied on first write.
Resident memory per live instance is what it wrote, about 4 MB for a CPython
request, not the 40 MB heap.

Where the image comes from decides whether it is mapped or copied:

| Load | Linux | macOS |
|---|---|---|
| `deserialize_file/1,2` | mapped from the file | mapped from the file |
| `deserialize/1,2` or `compile/1,2` | mapped from an anonymous file (memfd) | copied at every instantiation (1.9 ms for CPython) |

Use `deserialize_file/1,2` in production; it is the one that maps on both.

What a freed slot costs its next user differs too:

| | Linux | macOS |
|---|---|---|
| slot reset | written pages restored from the image in place, up to `keep_resident` bytes; the rest released | slot remapped to zeros |
| next instance | pages restored in place are already resident: no faults for them | image mapped again: the pages the guest touches fault in again |

On Linux 6.7 and later Wasmtime finds the written pages with the
`PAGEMAP_SCAN` ioctl, so `keep_resident` can cover the whole image (64 MB
for CPython) and a reset costs only what the request wrote. On older kernels
it restores all `keep_resident` bytes at every reset: keep it at 0 there,
or a few MB. On macOS every request pays the page faults
of what it touches, which is why `handle` takes 1.2 ms there against 0.6 ms
on a fully copied heap. The total is still lower, and the faults grow the
kernel's share of the time as concurrency rises.

`preinit/3` lays the snapshot out so the image is built at all: Wasmtime
only maps an image whose data covers at least half the span it initializes
(or spans under 16 MB), and copies every segment at each instantiation
otherwise. The heap of a started CPython is mostly zeros, so the smallest
zero gaps are filled in until the rule holds; the result is larger (50 MB
for 7 MB of live data) and instantiates in a tenth of the time.

## What the snapshot carries, and what it does not

Carried: every defined memory, every mutable global, the memory sizes. The
start section and `_initialize` (when it was one of the calls) are removed
from the result, since they already ran; `remove_exports` removes others,
such as `init`.

Not carried, so it must be the same or absent when the result runs:

- **Preopens.** The guest's C library reads the preopen table during
  `_initialize`, so the table is in the image. Give every instance the same
  `dirs`, in the same order, as the init instance. The host paths may
  differ; the guest paths and order may not. A preopen added later is
  invisible to the guest.
- **Open files and anything else the host holds.** A file the init left
  open is a dangling descriptor afterwards.
- **Randomness.** Whatever the init drew is in the image, so every instance
  starts with it: CPython's hash seed and the `random` module's state are the
  same in every request. Reseed in the request if that matters.
- **Time.** Monotonic readings taken during the init stay valid, because
  `clocks => monotonic` serves the host's monotonic clock rather than one
  starting at instantiation.
- **Tables.** The result's tables are rebuilt from its element segments. An
  init call that changes a table fails the capture with
  `kind => table_changed`.

Refused, with `class => preinit`:

| Module | `kind` |
|---|---|
| imports a memory, table or global | `unsupported_import` |
| declares GC types (structs, arrays) or a mutable reference global | `unsupported_type` |
| declares a shared memory, or is a component | `unsupported` |
| is not a WebAssembly binary | `malformed` |
| uses an export name starting with `__wasmtime_preinit_` | `unsupported` |
| an init call changed a table | `table_changed` |

## Notes

- Wizer also refuses modules whose code contains `data.drop` or
  `elem.drop`. `preinit/3` does not scan the code: a segment dropped during
  the init is present again in the result, so a later `memory.init` or
  `table.init` on it succeeds where the original would trap. Compilers do not
  emit such code for single-threaded modules.
- `wat2wasm/1` gives the binary form `preinit/3` needs when you start from
  text.
- The runtime-only build has no compiler, so it cannot pre-initialize; do it
  on a full build and ship the `.cwasm`.
- Pooled engines count against the 32 engines per VM like any compile
  option set, and a pool of `instances` slots reserves about 4 GB of address
  space per slot when its engine is created. A host that cannot reserve it
  (`ulimit -v`, strict overcommit) gets `kind => pool_too_large`.
