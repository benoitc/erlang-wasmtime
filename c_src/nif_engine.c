/*
 * nif_engine.c: Engines: one per compile option set, never freed, capped at
 * MAX_ENGINES; the epoch ticker; the stdin shim module compiled or loaded
 * per engine. make_config is mirrored by scripts/precompile-shims.sh.
 */
#include "nif.h"

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

/* Key :: {Fuel :: boolean(), none | speed | speed_and_size, [{Proposal, boolean()}]} */
static int parse_key(ErlNifEnv *env, ERL_NIF_TERM key, engine_t *k) {
  const ERL_NIF_TERM *t;
  int arity;
  char buf[32];
  if (!enif_get_tuple(env, key, &arity, &t) || arity != 3) return 0;
  memset(k, 0, sizeof *k);
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
         a->val_mask == b->val_mask;
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
  const char *missing = NULL;
  wasm_config_t *cfg = make_config(&want, &missing);
  if (!cfg) {
    pthread_mutex_unlock(&engines_mu);
    char msg[96];
    snprintf(msg, sizeof msg, "this build of erlang_wasmtime cannot set the %s proposal", missing);
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

/* The key back as {Fuel, OptLevel, [{Proposal, Bool}]}. */
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
  return enif_make_tuple3(env, e->fuel ? atom_true : atom_false, mk_atom(env, levels[e->opt_level]),
                          list);
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
    wasm_engine_delete(e->engine);
    enif_free(e);
  }
  nengines = 0;
  pthread_mutex_unlock(&engines_mu);
}
