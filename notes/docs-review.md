# Documentation and maintainability review

Reviewed: `main` at 8c6586a (0.3.0 merged, not tagged, not published),
2026-11-19. This is a plan. Nothing in it is done yet. The next review
updates this file instead of starting over.

## Summary

The project is in good shape for a human reader. The user guides follow one
template, `docs/design.md` states the rules a change must keep, the C is one
file per mechanism with a header comment each, and no function is longer
than about 80 lines. The problems are small and of three kinds:

1. Stale statements left by the split of the NIF and by 0.3.0 (wrong file
   names, a suite table missing two suites, a constant that moved).
2. No orientation page between the README and the guides: the vocabulary
   (engine, module, instance, store, handle, guest, host, shape, shim,
   reactor, `.cwasm`) is used everywhere and defined nowhere in one place.
3. The contributor path covers "add a NIF function" well and nothing for
   components, pre-initialization, or following one call through the system.

Nothing found needs a code split.

## 1. Recommended structure

| Step | Reader | Pages |
|---|---|---|
| Orientation | anyone | `README.md`, new `docs/concepts.md` |
| Use it | library user | getting-started, host-functions, wasi, streams, references, precompiled, components, preinit, javascript, python, troubleshooting, features |
| Operate it | user shipping it | building, throughput |
| Understand it | contributor | `docs/design.md` |
| Change it | contributor | `CONTRIBUTING.md`, `RELEASING.md` |

## 2. Starting point

`README.md`, then `docs/getting-started.md` for a user, `docs/concepts.md`
then `docs/design.md` for a contributor. The README's documentation list
should say so in one line per audience instead of one flat list of 16
links. Today it opens with "Run JavaScript" and "Run Python" before
"Getting started", while the ex_doc sidebar puts "Getting started" first.

## 3 and 4. Each document: purpose and verdict

| Document | Lines | Reader, purpose | Verdict |
|---|---|---|---|
| `README.md` | 95 | anyone: what it is, install, where next | Keep. Group the doc links by audience. "What you get" is 13 bullets, close to `features.md`: cut to the five that decide adoption and link to features. |
| `docs/getting-started.md` | 175 | first embed | Keep. Add a "Read next" line at the end. Sections after "Run a call without blocking" (compile options, fuel, globals, memory) are reference material: fine here, but name them "Going further". |
| `docs/host-functions.md` | 118 | guest calls Erlang | Keep. |
| `docs/wasi.md` | 131 | stock WASI binaries | Keep. It owns the WASI 0.2 comparison table; see components. |
| `docs/components.md` | 136 | component guests | Keep. Its "WASI 0.2" section repeats the intro of the one in `wasi.md`: keep the example, drop the repeated key list. |
| `docs/streams.md` | 138 | long-running guests | Keep. |
| `docs/references.md` | 114 | funcref, externref, GC | Keep. |
| `docs/precompiled.md` | 95 | start-up time, runtime-only nodes | Keep. |
| `docs/preinit.md` | 187 | per-request fresh interpreter | Keep. "How the memory image is shared" (50 lines) is design material a user needs only to size a pool: keep the platform table, move the mechanism to `design.md`, "Pre-initialization". |
| `docs/throughput.md` | 165 | sizing | Keep. Says "hornbeam's reactor" without saying what hornbeam or a reactor is: one sentence, or a link to concepts. |
| `docs/javascript.md`, `docs/python.md` | 172, 159 | recipes | Keep. The two share a structure and about half their prose; acceptable for recipes read alone. |
| `docs/building.md` | 181 | builds that differ from the default | Keep. "Building the archives" and "Upgrade Wasmtime" are maintainer tasks: replace with a link to `RELEASING.md`. |
| `docs/troubleshooting.md` | 80 | error lookup | Keep. No entry for component errors (`kind => component`, `clock_refused`, a trapped instance that cannot be re-entered, unversioned `wasi:*` link errors). Add them. |
| `docs/features.md` | 142 | what exists, what is refused | Keep. "Execution model" is the best short description of the runtime and is hidden in a status page: move it to `concepts.md` and link back. |
| `docs/design.md` | 433 | contributor: rules and reasons | Keep as one page. Fix the stale items in section 8. Add a "Follow one call" walk (section 12). |
| `CONTRIBUTING.md` | 120 | contributor: mechanics | Keep. Suite table lacks `wasmtime_component_SUITE` (391 lines) and `wasmtime_preinit_SUITE` (453). Add the missing "If you want to" entries (section 11). |
| `RELEASING.md` | 64 | maintainer | Keep. |
| `AGENTS.md` | 72 | coding agents | Rewrite the stale lines: it names `c_src/wasmtime_nif.c` twice (the file is gone, the C is `c_src/nif_*.c`) and says "Both suites" (there are eleven). |
| `examples/README.md` | - | user | Keep. |
| `CHANGELOG.md` | 139 | user | 0.3.0 is dated 2026-10-02; it merged on 2026-11-19 and is not published. Set the date to the publish day. |

## 5. Missing documents

**`docs/concepts.md`** (new, about 100 lines).
Intent: the mental model before any API. Reader: a new user or contributor
who knows Erlang and has heard of WebAssembly. After reading: they can name
engine, module, instance, store, handle, guest, host function, import shape,
core module against component, preview 1 against WASI 0.2, `.cwasm`,
pre-initialized module, pool slot, and say which process and which thread
does what during a call. Points next to: getting-started (users),
design (contributors). Level: one paragraph per term, one diagram, no API
listing. Most of the text exists already in `features.md` "Execution model"
and the `wasmtime` moduledoc.

No other new page is needed. The remaining gaps are sections in existing
pages.

## 6. Concepts that need a dedicated explanation

All in `concepts.md`:

- engine, module, instance, store, handle, and who owns what (user level;
  `design.md` "Ownership" is the contributor level);
- the calling process waits in `receive`, the guest runs on its own thread;
- where a host function runs;
- core module and component, preview 1 and WASI 0.2, and that the kind of
  binary decides, not an option;
- reactor and command (used in preinit, throughput, python, wasi);
- the error map `#{class, kind, message}` and where the kinds are listed;
- import shape and why instances of one module share a linker.

## 7. Navigation: concept to code to tests

To add to `design.md` "Where things are" as a third and fourth column, or
as a second table. Today that table gives the source file and never the
suite or the guide.

| Concept | Guide | Erlang | C | Suite |
|---|---|---|---|---|
| Compile, validate, inspect, engine options | getting-started, precompiled | `wasmtime.erl` (modules section), `wasmtime_options.erl` | `nif_engine.c`, `nif_api.c` | `wasmtime_module_SUITE` |
| Instantiate, options, limits | getting-started | `wasmtime.erl` `nif_options/3` | `nif_instantiate.c` | `wasmtime_memory_SUITE`, `wasmtime_SUITE` |
| Calls, timeouts, interruption, caller death | getting-started | `wasmtime.erl` `wait_result/3` | `nif_instance.c`, `nif_call.c` | `wasmtime_call_SUITE`, `wasmtime_SUITE` |
| Values | getting-started | - | `nif_values.c` | `wasmtime_call_SUITE` |
| References | references | - | `nif_refs.c`, `nif_values.c` | `wasmtime_ref_SUITE` |
| Host functions | host-functions | `wasmtime.erl` `run_host/4` | `nif_host.c` | `wasmtime_host_SUITE` |
| WASI preview 1, clocks | wasi | `wasmtime.erl` `wasi_options/1` | `nif_instantiate.c`, `nif_clock.c` | `wasmtime_wasi_SUITE` |
| Streams, the shim | streams | - | `nif_stream.c`, `nif_os.c`, `scripts/stdin-shim.wat` | `wasmtime_stream_SUITE` |
| Components, WIT values, WASI 0.2 | components, wasi | `wasmtime.erl` | `nif_component.c`, `nif_cvalues.c` | `wasmtime_component_SUITE`, `test/fixtures/components` |
| Pre-initialization | preinit | `wasmtime_preinit.erl` | `nif_preinit.c` | `wasmtime_preinit_SUITE` |
| Pooling allocator | preinit, throughput | `wasmtime_options.erl` | `nif_engine.c`, `nif_os.c` | `wasmtime_module_SUITE`, `wasmtime_preinit_SUITE` |
| Runtime-only build | building, precompiled | - | `scripts/build-nif.sh` | `wasmtime_runtime_only_SUITE` |
| Error terms | troubleshooting, features | - | `nif_atoms.c` | every suite |
| Build and download | building | - | `scripts/fetch-wasmtime.sh`, `build-nif.sh` | `scripts/test-fetch.sh` |

The suite column for the pooling row is a guess from names; check it when
writing the table.

## 8. Modules that need better documentation

| Where | Problem | Kind |
|---|---|---|
| `c_src/nif.h` header | Says "wasmtime_nif.c: Wasmtime bindings for Erlang". The file is the shared header of 15 files. | documentation |
| `docs/design.md`, "Numbers", pool row | Says the pool bounds are "the same in `wasmtime.erl`". They are in `wasmtime_options.erl` since 16d2961. `POOL_MAX_SLOTS` (100,000, both sides) has no row. | documentation |
| `docs/design.md`, "Where things are" | No row for `nif_atoms.c` (error terms), `nif_os.c`, `nif.h`; no test or guide column. | navigation |
| `src/wasmtime_nif.erl` | 42 stubs, no comment saying it is only the stub table and where the contract of each lives. One line is enough. | documentation |
| `src/wasmtime.erl` | Section banners exist (modules, instances, calls, memory) but components, references, streams and resources sit under "calls" and "memory". Add banners; no move needed. | navigation |
| `test/wasmtime_test.erl` | 320 lines of helpers used by every suite, mentioned once in CONTRIBUTING. A header listing what it offers (WAT compile, hand-assembled binaries, `needs/2`) would save a read. | documentation |
| `bench/` | Two benchmarks, each explained only inside `throughput.md`. A three-line `bench/README.md` or a paragraph in CONTRIBUTING "Measure" for the agent bench (`scripts/build-agent.sh`, `bench-agent.sh`), which CONTRIBUTING does not mention. | navigation |

## 9. Size and responsibilities

| Module | Lines | Functions | Exports | Reading |
|---|---|---|---|---|
| `src/wasmtime.erl` | 1,062 | about 92 clauses | 62 | Public API. Half the file is `-doc` and types. One responsibility: validate, default, call the NIF, wait. Fine. It sits just under the lint's length limit (see 16d2961), so the next feature will hit it: question 1. |
| `src/wasmtime_preinit.erl` | 625 | about 112 clauses | 1 entry | A Wasm binary parser, an instrumenter and a rewriter in one module. Coherent (one algorithm, three passes, said in the header), longest function 40 lines. Fine. A split into parse and rewrite would only pay if a second user of the parser appears. |
| `c_src/nif_api.c` | 839 | 38 | - | "Entry points not owned by another file" plus the table, load and unload. This is the one file whose content is defined by what it is not. It holds compile, deserialize, instantiate, memory, globals and tables entry points. Primary problem: module organisation, mild. Documentation first: list in its header which groups live there. |
| `c_src/nif_cvalues.c` | 599 | 17 | - | One responsibility, recursive by nature. Fine. |
| `c_src/nif_instantiate.c` | 513 | 14 | - | Options, WASI, import binding, the linker cache. The linker cache (`link_entry`) is a distinct idea with its own rules in design.md. Leave; note for later. |
| `c_src/nif_stream.c` | 499 | 26 | - | Inbox, pump thread, stdout callback, `erlang.*` imports. Coherent. |
| `c_src/nif.h` | 463 | - | - | Every struct. Central by design; `design.md` explains the fields. Fine. |

Counts come from pattern matches and are approximate.

## 10. Long functions

None worth a change. The longest: `worker_main` (79 lines,
`nif_instance.c`), `component_call` (78, `nif_component.c`), `open_atoms`
(72, a list), `make_config` (65, mirrored by `precompile-shims.sh`),
`do_call` (61). In Erlang: `instantiate` (47 with its doc),
`deserialize_file` (44), `rewrite_section` (40).

## 11. "If you want to" guides

Present in CONTRIBUTING: add a NIF function, add a value or reference kind,
add an instantiate or WASI option. To add, each five to ten lines pointing
at files, the design section to read first, and the suite:

- add or change a WIT value mapping (`nif_cvalues.c`, the three rules in
  design "Components", `wasmtime_component_SUITE`, keep erlang_wasm's
  mapping);
- add a component host import form;
- rebuild the component fixtures (`scripts/build-component-fixtures.sh`,
  `test/fixtures/components`);
- add a compile option or a proposal switch (`wasmtime_options.erl`,
  `nif_engine.c` `make_config`, `scripts/precompile-shims.sh`, the
  `.cwasm` compatibility table);
- add an error `kind` (`nif_atoms.c`, `features.md`, `troubleshooting.md`);
- change what a snapshot carries (`wasmtime_preinit.erl`, `nif_preinit.c`,
  `wasmtime_preinit_SUITE`);
- debug a call that hangs or answers `busy` (the state machine table, which
  fields to look at);
- support a new platform (`fetch-wasmtime.sh`, the runtime workflow, the
  shims), today spread over building and RELEASING.

## 12. Diagrams and examples

- `concepts.md`: one diagram of caller process, instance thread, store,
  host process, with the four messages.
- `design.md`: a sequence diagram "Follow one call": `call/4`, `enqueue`,
  `worker_main`, `host_exchange`, `{wasmtime_host_call, ...}`,
  `host_reply/3`, `{wasmtime_result, ...}`, and the timeout branch through
  `cancel/2`. The tables hold all of it; the order in time is what a
  newcomer lacks.
- `design.md`: a state diagram for `ST_IDLE`, `ST_RUNNING`, `ST_IN_HOST`
  next to the transition table.

## 13. Questions for the maintainer

1. `wasmtime.erl` is at the lint's length limit. When the next feature
   lands, do you prefer moving a group out (components and resources, or
   memory, globals and tables) or raising the limit for the API module?
2. The shim's unused `fd_read` forwarder stays "so the precompiled shims
   need not be rebuilt". Should it go at the next Wasmtime bump, when the
   shims are rebuilt anyway? If yes, RELEASING should say so.
3. `docs/` ships in the hex package, design.md included, and ex_doc
   publishes Design, Contributing and Releasing on hexdocs. Intended, or
   should the contributor pages stay on GitHub only?
4. Is the README order (JavaScript and Python first) deliberate, as the
   shortest path to a demo?
5. `nif_api.c`: keep it as the home of everything not owned elsewhere, or
   would you rather see the memory, global and table entry points in their
   own file at some point?

## 14. Suggested order

Before publishing 0.3.0 (all documentation, about an hour):

1. Stale statements: `AGENTS.md`, the `nif.h` header comment, the pool row
   and `POOL_MAX_SLOTS` in `design.md`, the suite table in CONTRIBUTING,
   the CHANGELOG date. The `nif.h` line is a comment in a source file: say
   if you want it in this pass or left for a code change.
2. Component entries in `troubleshooting.md`.

After the release:

3. `docs/concepts.md`, with "Execution model" moved from `features.md`;
   README links grouped by audience.
4. Navigation table with guides and suites in `design.md`; rows for
   `nif_atoms.c`, `nif_os.c`.
5. "Follow one call" and the state diagram in `design.md`.
6. The "If you want to" entries in CONTRIBUTING, the agent bench under
   "Measure".
7. Small moves: preinit mechanism to design, maintainer sections of
   building to RELEASING, the repeated WASI 0.2 intro, banners in
   `wasmtime.erl`, header of `wasmtime_test.erl`.

## Decisions (2026-11-19)

- Before publishing 0.3.0: stale statements and the component entries in
  `troubleshooting.md`. Done on `docs-review`, except the `nif.h` header
  comment (a source file, left for a code change).
- `wasmtime.erl` and the lint length limit: as in erlang_quic. Size rules
  keep their default and a module that outgrows one goes in the rule's
  `ignore` list with its reason. `elvis.config`, the erlfmt file list and
  `AGENTS.md` now follow erlang_quic's layout, adapted. Done on
  `docs-review`.
- CHANGELOG: 0.3.0 is marked unreleased until the publish day.
- Open: questions 2 to 5.
