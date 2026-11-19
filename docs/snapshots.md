# Snapshots

A snapshot is an image of an instance taken after its initialization.
Restoring it gives a new instance that is already initialized, so you skip
the guest's start-up and still give each request its own instance. You need
it when a guest takes long to start and little to run, such as an
interpreter that loads its standard library. The functions are erlang_wasm's:
`snapshot/1,2`, `restore/3`, `save_snapshot/2`, `load_snapshot/2`.

Use [`preinit/3`](preinit.md) instead when the initialization is known at
build time: it does the same from the module's bytes, without a running
node's cache.

## Capture one

```erlang
{ok, _} = application:ensure_all_started(erlang_wasmtime),
{ok, Mod} = wasmtime:load_file("app.wasm"),
{ok, Init} = wasmtime:instantiate(Mod, Imports, #{snapshotable => true}),
{ok, _} = wasmtime:call(Init, ~"init", []),
{ok, Image} = wasmtime:snapshot(Init),
ok = wasmtime:destroy(Init).
```

The module must come from `load/1,2` and the instance must be made with
`snapshotable => true`.

## Restore per request

```erlang
{ok, Fresh} = wasmtime:restore(Image, Imports, #{}),
{ok, Reply} = wasmtime:call(Fresh, ~"handle", Args),
ok = wasmtime:destroy(Fresh).
```

You give the imports again: the image carries the guest's memory and
globals, not what the host held for it. The start section does not run; it
ran before the capture. `Opts` are `instantiate/3`'s.

With a worker, hand it the image's module:

```erlang
#{module := Restored} = wasmtime:snapshot_info(Image),
{ok, W} = wasmtime_instance_worker:start_link(Restored, #{imports => Imports}).
```

## Keep images across restarts

```erlang
ok = wasmtime:save_snapshot(Image, "/var/cache/app/app.snap"),

{ok, Mod} = wasmtime:load_file("app.wasm"),
{ok, Image} = wasmtime:load_snapshot("/var/cache/app/app.snap", Mod).
```

`load_snapshot/2` refuses an image captured from other bytes than `Mod`'s.
The directory is as trusted as your release: whoever can write the file
chooses what a restored instance starts with.

## Match an image to a configuration

```erlang
{ok, Image} = wasmtime:snapshot(Init, #{version => ~"2", compatibility_key => Key}),
{ok, Fresh} = wasmtime:restore(Image, Imports, #{compatibility_key => Key}).
```

A restore with another key, or without one, is `kind =>
snapshot_incompatible`. Build the key from what must be the same for the
image to be valid: the imports' names, the WASI configuration.
`snapshot_info/1` gives the `version` back.

## What is refused

| Refused | Error |
|---|---|
| an instance made without `snapshotable => true`, or restored from an image | `class => snapshot, kind => not_snapshotable` |
| a module from `compile/1,2` | `kind => module_not_loaded` |
| a call running on the instance | `kind => busy` |
| a table changed since the instance was made | `class => preinit, kind => table_changed` |
| imported memories, tables or globals; GC types; a component | `class => preinit`, as for `preinit/3` |
| an image file of another module | `kind => snapshot_incompatible` |
| a file that is missing or not an image | `kind => snapshot_not_read` |

## Notes

- An image is a module compiled to start in the captured state. Taking one
  costs a compile of the module (about 350 ms for CPython); restoring is an
  ordinary instantiation. With a pooled engine it is mapped copy-on-write;
  see [pre-initialization](preinit.md), "How the memory image is shared".
- `load_snapshot/2` compiles too. To skip that at start-up, `serialize/1`
  the image's module and keep the `.cwasm`; see [precompiled](precompiled.md).
- The image is compiled with the options its module was loaded with, so
  load the module with `allocator => pooling` to restore into a pool.
- An image lives as long as a process holds the term. `acquire/1` and
  `release/1` answer `ok` and do nothing; they are there for code written
  for erlang_wasm.
- A snapshotable instance is made from a copy of the module that exports
  its memories, globals and tables under names starting with
  `__wasmtime_preinit_`. `exports/1` does not list them; a module that
  already exports such a name is refused.
- What the image does not carry: open files, the WASI preopens, anything
  the host holds. Give a restored instance the same `dirs`, in the same
  order, as the captured one had.
- The image file holds the module in binary form, compressed. erlang_wasm's
  image files are another format; neither runtime reads the other's.
