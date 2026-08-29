# References

A reference is a WebAssembly value that points at something rather than
being a number: a function (`funcref`), a host object (`externref`) or a GC
object (`struct`, `array`, `i31`). You need them when a guest hands out
callbacks, when it should hold Erlang data it cannot read but can give back,
or when it builds GC data you want to inspect. Each crosses the boundary as
a term and can be passed back in a call, a host function reply, a global or
a table.

```erlang
-type value() :: ... | null | ref() | {i31, integer()}.
```

`null` is the null reference of any type; `{i31, N}` is an unboxed 31-bit
integer reference; `ref()` is an opaque term for everything else.
`ref_info/1` tells them apart:

```erlang
#{kind := externref | funcref | struct | array | anyref, instance := InstRef} =
    wasmtime:ref_info(Ref).
```

## Hand the guest an Erlang term

```erlang
{ok, Ref} = wasmtime:externref(Inst, #{user => 42}),
{ok, [Back]} = wasmtime:call(Inst, ~"process", [Ref]),
{ok, #{user := 42}} = wasmtime:externref_data(Back).
```

The guest can store an `externref` in globals and tables and return it; it
cannot look inside. The term is copied in by `externref/2` and copied out by
`externref_data/1`.

## Call a function the guest gave you

```wat
(table (export "handlers") 4 funcref)
(func (export "on_event") (param funcref) ...)
```

```erlang
{ok, Handler} = wasmtime:table_get(Inst, ~"handlers", 0),
#{kind := funcref} = wasmtime:ref_info(Handler),
{ok, [Result]} = wasmtime:call_ref(Inst, Handler, [1, 2], #{timeout => 1000}).
```

`call_ref/3,4` takes the options of `call/4` and follows the same rules,
including reentrancy: a host function that receives a `funcref` cannot call
it while it runs (the guest is parked), so keep it and call it once the
call returns.

## Read and write GC objects

A struct or array the guest created comes back as a `ref()`:

```erlang
{ok, [P]} = wasmtime:call(Inst, ~"make_point", [3, 2.5]),
#{kind := struct} = wasmtime:ref_info(P),
{ok, 3} = wasmtime:struct_get(P, 0),
ok = wasmtime:struct_set(P, 0, 30),
{ok, [A]} = wasmtime:call(Inst, ~"make_array", [9]),
{ok, 5} = wasmtime:array_len(A),
{ok, 9} = wasmtime:array_get(A, 4),
ok = wasmtime:array_set(A, 0, 100).
```

Fields and elements hold `value()`s, references included; `i8` and `i16`
fields take and give integers. An index past the end is
`{error, #{class := ref, kind := out_of_bounds}}`; a value of the wrong type
is `kind => badarg`; a field the guest declared immutable is refused by
Wasmtime. Wasmtime checks the type of a reference passed to a function
whose parameter is a concrete type, so passing a struct where
`(ref array)` is expected is an error, never a crash.

## Globals and tables

```erlang
{ok, null} = wasmtime:global_get(Inst, ~"current"),
ok = wasmtime:global_set(Inst, ~"current", Ref),
ok = wasmtime:table_set(Inst, ~"handlers", 2, Handler),
{ok, 4} = wasmtime:table_grow(Inst, ~"handlers", 2, Handler).
```

## Lifetime

- A `ref()` keeps its object alive: the guest's collector cannot reclaim it
  while the term exists. Drop the term (let it go out of scope) and the
  object is released when the guest no longer reaches it either. `gc/1` runs
  the collector now; otherwise Wasmtime runs it when it needs room.
- A `ref()` keeps its instance alive. It stays usable after you dropped the
  instance handle.
- A `ref()` belongs to one instance; using it with another is
  `kind => wrong_instance`.
- `externref/2` fails with `kind => gc_heap_full` when the GC heap is full;
  `gc/1` may make room.
- Reading or writing through a `ref()` needs the guest idle or parked in a
  host function, like memory access: `kind => busy` otherwise.

## Notes

- Creating a struct or array from Erlang is not offered: the C API needs a
  type handle that only an existing value provides. Have the guest export a
  constructor.
- `exnref` values cannot cross (`unsupported_type`). A function whose
  signature mixes `v128` and references cannot be called from Erlang or
  served as a host function; split it.
- On a build of the library without GC support, only `funcref` crosses and
  the others answer `kind => unavailable`; both shipped libraries have it.
- Under the hood a `ref()` is an owned Wasmtime root; its destructor unroots
  it from whatever thread it runs on. Not a single reference is tracked by
  hand anywhere, so leaking is a matter of holding terms, not of forgetting
  a release.
