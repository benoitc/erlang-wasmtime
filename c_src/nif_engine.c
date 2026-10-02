/*
 * nif_engine.c: Engines: one per compile option set, never freed, capped at
 * MAX_ENGINES; the epoch ticker; the stdin shim module compiled or loaded
 * per engine. make_config is mirrored by scripts/precompile-shims.sh.
 */
#include "nif.h"

/* Added by scripts/wasmtime-patches, so present in this project's Linux
 * and FreeBSD archives and in source builds, absent from upstream's macOS
 * archives: the weak reference is null there. docs/preinit.md. */
extern void
wasmtime_pooling_allocation_config_pagemap_scan_set(wasmtime_pooling_allocation_config_t *, bool)
    __attribute__((weak));

/* Mirrors pooling_key/3 in wasmtime.erl; docs/design.md, "Numbers". */
#define POOL_MAX_INSTANCES 10000 /* also the cap on memories: 4 GB of address space each */
#define POOL_MAX_SLOTS 100000    /* core instances and tables: about 1 MB and 160 KB each */
#define POOL_MAX_MEMORY (4ull << 30)
#define WASM_PAGE 65536

static const char *const proposal_names[NPROPOSALS] = {"simd",
                                                       "relaxed_simd",
                                                       "relaxed_simd_deterministic",
                                                       "bulk_memory",
                                                       "multi_value",
                                                       "multi_memory",
                                                       "memory64",
                                                       "tail_call",
                                                       "wide_arithmetic",
                                                       "custom_page_sizes",
                                                       "threads",
                                                       "reference_types",
                                                       "function_references",
                                                       "gc",
                                                       "exceptions"};

static engine_t *engines_head;

static int nengines;

static pthread_mutex_t engines_mu = PTHREAD_MUTEX_INITIALIZER;

/* Allocator :: on_demand
 *            | {pooling, Instances, MaxMemory, KeepResident, CoreInstances, Memories, Tables} */
static int parse_allocator(ErlNifEnv *env, ERL_NIF_TERM a, engine_t *k) {
  const ERL_NIF_TERM *t;
  int arity;
  char buf[16];
  ErlNifUInt64 n;
  if (enif_get_atom(env, a, buf, sizeof buf, ERL_NIF_LATIN1)) return strcmp(buf, "on_demand") == 0;
  if (!enif_get_tuple(env, a, &arity, &t) || arity != 7 ||
      !enif_get_atom(env, t[0], buf, sizeof buf, ERL_NIF_LATIN1) || strcmp(buf, "pooling") != 0)
    return 0;
  k->pooling = 1;
  /* The bounds pooling_key/3 in wasmtime.erl checks, again: Wasmtime
   * aborts the process on a pool it cannot build. */
  if (!enif_get_uint64(env, t[1], &n) || n == 0 || n > POOL_MAX_INSTANCES) return 0;
  k->pool_instances = (uint32_t)n;
  if (!enif_get_uint64(env, t[2], &k->pool_max_memory) ||
      !enif_get_uint64(env, t[3], &k->pool_keep_resident))
    return 0;
  ErlNifUInt64 c, m, tb;
  if (!enif_get_uint64(env, t[4], &c) || c == 0 || c > POOL_MAX_SLOTS ||
      !enif_get_uint64(env, t[5], &m) || m == 0 || m > POOL_MAX_INSTANCES ||
      !enif_get_uint64(env, t[6], &tb) || tb == 0 || tb > POOL_MAX_SLOTS)
    return 0;
  k->pool_core_instances = (uint32_t)c;
  k->pool_memories = (uint32_t)m;
  k->pool_tables = (uint32_t)tb;
  return k->pool_max_memory >= WASM_PAGE && k->pool_max_memory <= POOL_MAX_MEMORY &&
         k->pool_max_memory % WASM_PAGE == 0 && k->pool_keep_resident <= k->pool_max_memory;
}

/* Key :: {Fuel :: boolean(), none | speed | speed_and_size, [{Proposal, boolean()}], Allocator} */
static int parse_key(ErlNifEnv *env, ERL_NIF_TERM key, engine_t *k) {
  const ERL_NIF_TERM *t;
  int arity;
  char buf[32];
  if (!enif_get_tuple(env, key, &arity, &t) || arity != 4) return 0;
  memset(k, 0, sizeof *k);
  if (!parse_allocator(env, t[3], k)) return 0;
  if (enif_is_identical(t[0], atom_true))
    k->fuel = 1;
  else if (!enif_is_identical(t[0], atom_false))
    return 0;
  if (!enif_get_atom(env, t[1], buf, sizeof buf, ERL_NIF_LATIN1)) return 0;
  if (strcmp(buf, "none") == 0)
    k->opt_level = 0;
  else if (strcmp(buf, "speed") == 0)
    k->opt_level = 1;
  else if (strcmp(buf, "speed_and_size") == 0)
    k->opt_level = 2;
  else
    return 0;
  ERL_NIF_TERM l = t[2], h;
  const ERL_NIF_TERM *pv;
  while (enif_get_list_cell(env, l, &h, &l)) {
    if (!enif_get_tuple(env, h, &arity, &pv) || arity != 2 ||
        !enif_get_atom(env, pv[0], buf, sizeof buf, ERL_NIF_LATIN1))
      return 0;
    int i;
    for (i = 0; i < NPROPOSALS && strcmp(buf, proposal_names[i]) != 0; i++) {
    }
    if (i == NPROPOSALS) return 0;
    k->set_mask |= 1u << i;
    if (enif_is_identical(pv[1], atom_true))
      k->val_mask |= 1u << i;
    else if (!enif_is_identical(pv[1], atom_false))
      return 0;
  }
  return 1;
}

static int same_key(const engine_t *a, const engine_t *b) {
  return a->fuel == b->fuel && a->opt_level == b->opt_level && a->set_mask == b->set_mask &&
         a->val_mask == b->val_mask && a->pooling == b->pooling &&
         a->pool_instances == b->pool_instances && a->pool_max_memory == b->pool_max_memory &&
         a->pool_keep_resident == b->pool_keep_resident &&
         a->pool_core_instances == b->pool_core_instances && a->pool_memories == b->pool_memories &&
         a->pool_tables == b->pool_tables;
}

/* The proposal setters exist per build feature; a toggle the headers do not
 * declare is refused rather than ignored. Returns 0 or the missing name. */
static const char *apply_proposal(wasm_config_t *cfg, int i, int on) {
  switch (i) {
  case 0: wasmtime_config_wasm_simd_set(cfg, on); return 0;
  case 1: wasmtime_config_wasm_relaxed_simd_set(cfg, on); return 0;
  case 2: wasmtime_config_wasm_relaxed_simd_deterministic_set(cfg, on); return 0;
  case 3: wasmtime_config_wasm_bulk_memory_set(cfg, on); return 0;
  case 4: wasmtime_config_wasm_multi_value_set(cfg, on); return 0;
  case 5: wasmtime_config_wasm_multi_memory_set(cfg, on); return 0;
  case 6: wasmtime_config_wasm_memory64_set(cfg, on); return 0;
  case 7: wasmtime_config_wasm_tail_call_set(cfg, on); return 0;
  case 8: wasmtime_config_wasm_wide_arithmetic_set(cfg, on); return 0;
  case 9: wasmtime_config_wasm_custom_page_sizes_set(cfg, on); return 0;
#ifdef WASMTIME_FEATURE_THREADS
  case 10: wasmtime_config_wasm_threads_set(cfg, on); return 0;
#endif
#ifdef WASMTIME_FEATURE_GC
  case 11: wasmtime_config_wasm_reference_types_set(cfg, on); return 0;
  case 12: wasmtime_config_wasm_function_references_set(cfg, on); return 0;
  case 13: wasmtime_config_wasm_gc_set(cfg, on); return 0;
  case 14: wasmtime_config_wasm_exceptions_set(cfg, on); return 0;
#endif
  default: return proposal_names[i];
  }
}

/* Find or create the engine for a key. Returns the entry, or 0 with *err
 * set to an error term in `env`. */
/* The engine config for a key. NULL with *missing set when a proposal in
 * the key cannot be set on this build. scripts/precompile-shims.sh mirrors
 * these settings; keep the two in step. */
static wasm_config_t *make_config(const engine_t *want, const char **missing) {
  wasm_config_t *cfg = wasm_config_new();
  wasmtime_config_epoch_interruption_set(cfg, true);
  wasmtime_config_consume_fuel_set(cfg, want->fuel);
  /* Engine settings are part of a precompiled module's compatibility check.
   * Runtime-only builds have no component model, so the full build must not
   * compile modules with the concurrency support it would otherwise enable
   * by default; nothing here uses components. */
#ifdef WASMTIME_FEATURE_COMPONENT_MODEL
  wasmtime_config_concurrency_support_set(cfg, false);
#endif
#if NIF_HAVE_COMPILER
  wasmtime_config_cranelift_opt_level_set(cfg, want->opt_level == 0 ? WASMTIME_OPT_LEVEL_NONE
                                               : want->opt_level == 1
                                                   ? WASMTIME_OPT_LEVEL_SPEED
                                                   : WASMTIME_OPT_LEVEL_SPEED_AND_SIZE);
#endif
  /* Copy-on-write images are Wasmtime's default; stated because the
   * pre-initialized modules of docs/preinit.md rely on them. */
  wasmtime_config_memory_init_cow_set(cfg, true);
#ifdef WASMTIME_FEATURE_POOLING_ALLOCATOR
  if (want->pooling) {
    /* The allocator is not recorded in a precompiled module: the same
     * .cwasm loads on either. The bounds were checked in Erlang. */
    wasmtime_pooling_allocation_config_t *pc = wasmtime_pooling_allocation_config_new();
    wasmtime_pooling_allocation_config_total_core_instances_set(pc, want->pool_core_instances);
    wasmtime_pooling_allocation_config_total_memories_set(pc, want->pool_memories);
    wasmtime_pooling_allocation_config_total_tables_set(pc, want->pool_tables);
#ifdef WASMTIME_FEATURE_GC
    wasmtime_pooling_allocation_config_total_gc_heaps_set(pc, want->pool_memories);
#endif
#ifdef WASMTIME_FEATURE_COMPONENT_MODEL
    /* A component may use what the whole pool holds: Wasmtime refuses at
     * compile time one that needs more than these. */
    wasmtime_pooling_allocation_config_total_component_instances_set(pc, want->pool_instances);
    wasmtime_pooling_allocation_config_max_core_instances_per_component_set(
        pc, want->pool_core_instances);
    wasmtime_pooling_allocation_config_max_memories_per_component_set(pc, want->pool_memories);
    wasmtime_pooling_allocation_config_max_tables_per_component_set(pc, want->pool_tables);
#endif
    wasmtime_pooling_allocation_config_max_memory_size_set(pc, (size_t)want->pool_max_memory);
    wasmtime_pooling_allocation_config_linear_memory_keep_resident_set(
        pc, (size_t)want->pool_keep_resident);
    if (wasmtime_pooling_allocation_config_pagemap_scan_set)
      wasmtime_pooling_allocation_config_pagemap_scan_set(pc, true);
    wasmtime_pooling_allocation_strategy_set(cfg, pc);
    wasmtime_pooling_allocation_config_delete(pc);
  }
#else
  if (want->pooling) {
    wasm_config_delete(cfg);
    *missing = "pooling allocator";
    return NULL;
  }
#endif
  for (int i = 0; i < NPROPOSALS; i++) {
    if (!(want->set_mask & (1u << i))) continue;
    const char *m = apply_proposal(cfg, i, (want->val_mask >> i) & 1);
    if (m) {
      wasm_config_delete(cfg);
      *missing = m;
      return NULL;
    }
  }
  return cfg;
}

engine_t *engine_for(ErlNifEnv *env, ERL_NIF_TERM key, ERL_NIF_TERM *err) {
  engine_t want;
  if (!parse_key(env, key, &want)) {
    *err = enif_make_badarg(env);
    return 0;
  }
  pthread_mutex_lock(&engines_mu);
  for (engine_t *e = engines_head; e; e = e->next) {
    if (same_key(e, &want)) {
      pthread_mutex_unlock(&engines_mu);
      return e;
    }
  }
  if (nengines >= MAX_ENGINES) {
    pthread_mutex_unlock(&engines_mu);
    *err = mk_error_s(env, "compile", "too_many_configurations",
                      "at most 32 distinct compile option sets per VM");
    return 0;
  }
#if !NIF_HAVE_COMPILER
  if (want.opt_level != 1) {
    pthread_mutex_unlock(&engines_mu);
    *err = mk_error_s(env, "compile", "unavailable",
                      "this build of erlang_wasmtime has no compiler: opt_level must be speed");
    return 0;
  }
#endif
  if (want.pooling && !pool_fits(want.pool_memories, want.pool_core_instances)) {
    pthread_mutex_unlock(&engines_mu);
    *err = mk_error_s(env, "compile", "pool_too_large",
                      "this host cannot reserve the address space for that many pooled memories "
                      "(about 4 GB each): lower pooling memories or instances");
    return 0;
  }
  const char *missing = NULL;
  wasm_config_t *cfg = make_config(&want, &missing);
  if (!cfg) {
    pthread_mutex_unlock(&engines_mu);
    char msg[96];
    if (!missing) missing = "setting";
    snprintf(msg, sizeof msg, "this build of erlang_wasmtime has no %s%s", missing,
             strcmp(missing, "pooling allocator") == 0 ? "" : " proposal");
    *err = mk_error_s(env, "compile", "unavailable", msg);
    return 0;
  }
  engine_t *e = enif_alloc(sizeof *e);
  *e = want;
  e->engine = wasm_engine_new_with_config(cfg); /* consumes cfg */
  e->next = engines_head;
  engines_head = e;
  nengines++;
  pthread_mutex_unlock(&engines_mu);
  return e;
}

/* The key back as {Fuel, OptLevel, [{Proposal, Bool}], Allocator}. */
ERL_NIF_TERM key_term(ErlNifEnv *env, const engine_t *e) {
  static const char *const levels[3] = {"none", "speed", "speed_and_size"};
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (int i = NPROPOSALS - 1; i >= 0; i--) {
    if (!(e->set_mask & (1u << i))) continue;
    list = enif_make_list_cell(env,
                               enif_make_tuple2(env, mk_atom(env, proposal_names[i]),
                                                (e->val_mask >> i) & 1 ? atom_true : atom_false),
                               list);
  }
  ERL_NIF_TERM pool[7] = {mk_atom(env, "pooling"),
                          enif_make_uint64(env, e->pool_instances),
                          enif_make_uint64(env, e->pool_max_memory),
                          enif_make_uint64(env, e->pool_keep_resident),
                          enif_make_uint64(env, e->pool_core_instances),
                          enif_make_uint64(env, e->pool_memories),
                          enif_make_uint64(env, e->pool_tables)};
  ERL_NIF_TERM alloc =
      e->pooling ? enif_make_tuple_from_array(env, pool, 7) : mk_atom(env, "on_demand");
  return enif_make_tuple4(env, e->fuel ? atom_true : atom_false, mk_atom(env, levels[e->opt_level]),
                          list, alloc);
}

static pthread_t ticker;

static volatile int ticker_stop;

/* Wasmtime's WASI functions find the guest memory through their caller's
 * "memory" export, and a host-to-host call has no caller. This module
 * imports the guest memory, exports it under that name and forwards to
 * Wasmtime's fd_read, so fd_read_cb calls it for every fd but 0:
 *
 *   (module
 *     (import "wasi" "fd_read" (func $r (param i32 i32 i32 i32) (result i32)))
 *     (import "wasi" "fd_fdstat_get" (func $s (param i32 i32) (result i32)))
 *     (import "guest" "memory" (memory 0))
 *     (export "memory" (memory 0))
 *     (func (export "fd_read") (param i32 i32 i32 i32) (result i32)
 *       local.get 0 local.get 1 local.get 2 local.get 3 call $r)
 *     (func (export "fd_fdstat_get") (param i32 i32) (result i32)
 *       local.get 0 local.get 1 call $s))
 *
 * scripts/stdin-shim.wat is the same text; keep the three in step.
 */
#if NIF_HAVE_COMPILER
static const uint8_t SHIM_WASM[] = {
    0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x0f, 0x02, 0x60, 0x04, 0x7f, 0x7f,
    0x7f, 0x7f, 0x01, 0x7f, 0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, 0x02, 0x35, 0x03, 0x04, 0x77,
    0x61, 0x73, 0x69, 0x07, 0x66, 0x64, 0x5f, 0x72, 0x65, 0x61, 0x64, 0x00, 0x00, 0x04, 0x77,
    0x61, 0x73, 0x69, 0x0d, 0x66, 0x64, 0x5f, 0x66, 0x64, 0x73, 0x74, 0x61, 0x74, 0x5f, 0x67,
    0x65, 0x74, 0x00, 0x01, 0x05, 0x67, 0x75, 0x65, 0x73, 0x74, 0x06, 0x6d, 0x65, 0x6d, 0x6f,
    0x72, 0x79, 0x02, 0x00, 0x00, 0x03, 0x03, 0x02, 0x00, 0x01, 0x07, 0x24, 0x03, 0x06, 0x6d,
    0x65, 0x6d, 0x6f, 0x72, 0x79, 0x02, 0x00, 0x07, 0x66, 0x64, 0x5f, 0x72, 0x65, 0x61, 0x64,
    0x00, 0x02, 0x0d, 0x66, 0x64, 0x5f, 0x66, 0x64, 0x73, 0x74, 0x61, 0x74, 0x5f, 0x67, 0x65,
    0x74, 0x00, 0x03, 0x0a, 0x17, 0x02, 0x0c, 0x00, 0x20, 0x00, 0x20, 0x01, 0x20, 0x02, 0x20,
    0x03, 0x10, 0x00, 0x0b, 0x08, 0x00, 0x20, 0x00, 0x20, 0x01, 0x10, 0x01, 0x0b};
#endif

/* The shim, once per engine: compiled here when the build can, otherwise
 * deserialized from the bytes Erlang read from priv/shims (produced by
 * scripts/precompile-shims.sh). NULL with *why set on failure. */
wasmtime_module_t *engine_shim(engine_t *e, ErlNifEnv *env, ERL_NIF_TERM shim, const char **why) {
  pthread_mutex_lock(&engines_mu);
  if (!e->shim) {
    wasmtime_module_t *m = NULL;
    wasmtime_error_t *err = NULL;
#if NIF_HAVE_COMPILER
    (void)env;
    (void)shim;
    err = wasmtime_module_new(e->engine, SHIM_WASM, sizeof SHIM_WASM, &m);
    if (err) *why = "the stdin shim did not compile";
#else
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, shim, &bin)) {
      *why = "no precompiled stdin shim for this platform: see docs/streams.md";
    } else {
      err = wasmtime_module_deserialize(e->engine, bin.data, bin.size, &m);
      if (err) *why = "the precompiled stdin shim does not match this engine";
    }
#endif
    if (err) wasmtime_error_delete(err);
    e->shim = m;
  }
  pthread_mutex_unlock(&engines_mu);
  return e->shim;
}

/* A linker holding only Wasmtime's WASI, once per engine. The instances'
 * own linkers shadow some WASI functions; this one is where the originals
 * are found (take_real_wasi). */
wasmtime_linker_t *engine_wasi_linker(engine_t *e) {
  pthread_mutex_lock(&engines_mu);
  if (!e->wasi) {
    wasmtime_linker_t *l = wasmtime_linker_new(e->engine);
#if NIF_HAVE_WASI
    wasmtime_error_t *err = wasmtime_linker_define_wasi(l);
    if (err) {
      wasmtime_error_delete(err);
      wasmtime_linker_delete(l);
      l = NULL;
    }
#endif
    e->wasi = l;
  }
  pthread_mutex_unlock(&engines_mu);
  return e->wasi;
}

static void *ticker_main(void *arg) {
  struct timespec ts = {0, EPOCH_TICK_NS};
  while (!__atomic_load_n(&ticker_stop, __ATOMIC_ACQUIRE)) {
    nanosleep(&ts, NULL);
    pthread_mutex_lock(&engines_mu);
    for (engine_t *e = engines_head; e; e = e->next) wasmtime_engine_increment_epoch(e->engine);
    pthread_mutex_unlock(&engines_mu);
  }
  return NULL;
}

/* Started at load; every engine's epoch is bumped from here. */
int ticker_start(void) {
  ticker_stop = 0;
  return pthread_create(&ticker, NULL, ticker_main, NULL) == 0;
}

void ticker_shutdown(void) {
  __atomic_store_n(&ticker_stop, 1, __ATOMIC_RELEASE);
  pthread_join(ticker, NULL);
}

/* Instances still alive at unload keep their own engine reference through
 * their store; deleting ours here only drops the handle taken at load. */
void engines_free_all(void) {
  pthread_mutex_lock(&engines_mu);
  while (engines_head) {
    engine_t *e = engines_head;
    engines_head = e->next;
    if (e->shim) wasmtime_module_delete(e->shim);
    if (e->wasi) wasmtime_linker_delete(e->wasi);
    wasm_engine_delete(e->engine);
    enif_free(e);
  }
  nengines = 0;
  pthread_mutex_unlock(&engines_mu);
}
