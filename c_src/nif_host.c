/*
 * nif_host.c: Host functions: a guest import backed by an Erlang fun. The
 * worker sends {wasmtime_host_call, ...} and waits, bounded, for
 * host_reply/3; two callbacks, raw and typed, share host_exchange.
 */
#include "nif.h"

static void add_ms(struct timespec *ts, unsigned ms) {
  clock_gettime(CLOCK_REALTIME, ts);
  ts->tv_sec += ms / 1000;
  ts->tv_nsec += (long)(ms % 1000) * 1000000L;
  if (ts->tv_nsec >= 1000000000L) {
    ts->tv_sec++;
    ts->tv_nsec -= 1000000000L;
  }
}

/* A host call that failed here, not in the fun: builds the host_error the
 * request answers with. `detail` may be NULL. */
static void set_host_failure(instance_t *inst, const hostfn_t *fn, const char *reason,
                             const char *detail) {
  ErlNifEnv *env = inst->host.error_env;
  enif_clear_env(env);
  ERL_NIF_TERM key = enif_make_tuple2(env, mk_binary(env, fn->module, strlen(fn->module)),
                                      mk_binary(env, fn->name, strlen(fn->name)));
  ERL_NIF_TERM keys[3] = {atom_reason, atom_host, atom_detail};
  ERL_NIF_TERM vals[3] = {mk_atom(env, reason), key, 0};
  if (detail) vals[2] = mk_binary(env, detail, strlen(detail));
  ERL_NIF_TERM ctx;
  enif_make_map_from_arrays(env, keys, vals, detail ? 3 : 2, &ctx);
  inst->host.error = mk_error_ctx(env, "trap", "host_error", "host error", 10, ctx);
  inst->host.failed = 1;
}

/* How the request that just ran ended, in priority order. Consumes `e` and
 * `trap`. A trap raised by a host callback comes back from Wasmtime as an
 * error wrapping a backtrace; the instance flags tell the real cause. */
ERL_NIF_TERM outcome(instance_t *inst, ErlNifEnv *out, wasmtime_error_t *e, wasm_trap_t *trap,
                     const char *cls) {
  if (inst->clock_refused) {
    if (e) wasmtime_error_delete(e);
    if (trap) wasm_trap_delete(trap);
    return mk_error_s(out, "trap", "clock_refused",
                      "the guest read the wall clock, which clocks => monotonic refuses");
  }
  if (inst->interrupted_fired || inst->host.failed) {
    if (e) wasmtime_error_delete(e);
    if (trap) wasm_trap_delete(trap);
    if (inst->interrupted_fired) return mk_error_s(out, "trap", "interrupt", "interrupted");
    return enif_make_copy(out, inst->host.error);
  }
  if (e) return error_to_term(out, e, cls);
  if (trap) return trap_to_term(out, trap);
  return atom_ok;
}

/* A reply usually comes within a few microseconds: the host process runs
 * the fun and calls host_reply/3. Waiting that long on the condition
 * variable costs a sleep and a wake-up, so look first, for at most
 * HOST_SPIN_NS, with the mutex released. Called and returns with it held. */
#define HOST_SPIN_NS 20000
static inline void cpu_relax(void) {
#if defined(__aarch64__)
  __asm__ __volatile__("yield");
#elif defined(__x86_64__)
  __asm__ __volatile__("pause");
#endif
}

static void spin_for_reply(instance_t *inst) {
  struct timespec t0, t;
  pthread_mutex_unlock(&inst->mu);
  clock_gettime(CLOCK_MONOTONIC, &t0);
  for (unsigned i = 1;; i++) {
    if (__atomic_load_n(&inst->host.has_reply, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&inst->host.abort, __ATOMIC_ACQUIRE))
      break;
    cpu_relax();
    if (i % 64 == 0) {
      clock_gettime(CLOCK_MONOTONIC, &t);
      if ((t.tv_sec - t0.tv_sec) * 1000000000L + (t.tv_nsec - t0.tv_nsec) > HOST_SPIN_NS) break;
    }
  }
  pthread_mutex_lock(&inst->mu);
}

/* Runs on the instance thread, inside wasmtime_func_call. The mutex is not
 * held while the guest runs, so take it here. */

/* Sends {wasmtime_host_call, Ref, Id, {Module, Name}, Args} (`args` lives in
 * `menv`, consumed here) and waits for the reply. Returns with the mutex
 * held. On HOST_OK, *results is the reply's result list in inst->host.reply_env;
 * on HOST_FAILED, inst->host.failed is set or *fail is the reason's atom. */
enum host_status host_exchange(instance_t *inst, hostfn_t *fn, ErlNifEnv *menv, ERL_NIF_TERM args,
                               ERL_NIF_TERM *results, const char **fail) {
  *fail = NULL;
  pthread_mutex_lock(&inst->mu);
  if (inst->host.abort || inst->queue.current->cancelled) {
    /* interrupted or cancelled before we got here: do not even ask */
    enif_free_env(menv);
    return HOST_INTERRUPTED;
  }
  inst->queue.state = ST_IN_HOST;
  inst->host.id = ++inst->host.seq;
  inst->host.has_reply = 0;
  /* A dedicated handler serves calls; the start section at instantiate
   * time goes to the caller, which is the only process that has the
   * instance at that point. */
  inst->host.target = inst->host.has_pid && inst->queue.current->kind == REQ_CALL
                          ? inst->host.pid
                          : inst->queue.current->caller;
  enif_clear_env(inst->host.reply_env);
  ERL_NIF_TERM msg =
      enif_make_tuple5(menv, atom_wasmtime_host_call, enif_make_copy(menv, inst->ref),
                       enif_make_uint64(menv, inst->host.id),
                       enif_make_tuple2(menv, mk_binary(menv, fn->module, strlen(fn->module)),
                                        mk_binary(menv, fn->name, strlen(fn->name))),
                       args);
  int sent = enif_send(NULL, &inst->host.target, menv, msg);
  enif_free_env(menv);
  int interrupted = 0;
  if (!sent) {
    *fail = "host_gone";
  } else {
    spin_for_reply(inst);
    struct timespec deadline;
    add_ms(&deadline, inst->host.timeout_ms);
    while (!inst->host.has_reply && !inst->host.abort) {
      if (pthread_cond_timedwait(&inst->cv, &inst->mu, &deadline) == ETIMEDOUT) {
        if (!inst->host.has_reply && !inst->host.abort) *fail = "host_timeout";
        break;
      }
    }
    if (!*fail && inst->host.abort) interrupted = 1;
  }
  inst->queue.state = ST_RUNNING;
  if (interrupted) return HOST_INTERRUPTED;
  if (*fail) return HOST_FAILED;

  /* {ok, Results} | {error, Map}: the error the request answers with */
  ErlNifEnv *renv = inst->host.reply_env;
  const ERL_NIF_TERM *tup;
  int arity;
  if (!enif_get_tuple(renv, inst->host.reply, &arity, &tup) || arity != 2) {
    *fail = "bad_reply";
    return HOST_FAILED;
  }
  if (enif_is_identical(tup[0], atom_error)) {
    if (!enif_is_map(renv, tup[1])) {
      *fail = "bad_reply";
      return HOST_FAILED;
    }
    enif_clear_env(inst->host.error_env);
    inst->host.error = enif_make_copy(inst->host.error_env, inst->host.reply);
    inst->host.failed = 1;
    return HOST_FAILED;
  }
  *results = tup[1];
  return HOST_OK;
}

/* After host_exchange, with the mutex released: the trap to return, if any. */
wasm_trap_t *host_outcome(instance_t *inst, const hostfn_t *fn, enum host_status st,
                          const char *fail, const char *detail) {
  if (st == HOST_INTERRUPTED) {
    inst->interrupted_fired = 1;
    return wasmtime_trap_new("interrupted", 11);
  }
  if (fail) set_host_failure(inst, fn, fail, detail);
  /* outcome() answers with the stored error; this only unwinds the guest */
  if (inst->host.failed) return wasmtime_trap_new("host error", 10);
  return NULL;
}

/* Runs on the instance thread, inside wasmtime_func_call, for imports whose
 * signature has no references: values cross as wasmtime_val_raw_t. */
wasm_trap_t *host_callback(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                           size_t nvals) {
  instance_t *inst = caller_inst(caller);
  hostfn_t *fn = &inst->wasm.entry->hostfns[(uintptr_t)envp];
  const wasm_valtype_vec_t *pt = wasm_functype_params(fn->type);
  const wasm_valtype_vec_t *rt = wasm_functype_results(fn->type);
  size_t nargs = pt->size, nresults = rt->size;
  const char *fail = NULL;

  /* Read every argument before any result is written: they share `vals`. */
  ErlNifEnv *menv = enif_alloc_env();
  ERL_NIF_TERM list = enif_make_list(menv, 0);
  for (size_t i = nargs; i > 0; i--)
    list =
        enif_make_list_cell(menv, raw_to_term(menv, kind_of(pt->data[i - 1]), &vals[i - 1]), list);

  ERL_NIF_TERM results;
  enum host_status st = host_exchange(inst, fn, menv, list, &results, &fail);
  if (st == HOST_OK) {
    ErlNifEnv *renv = inst->host.reply_env;
    ERL_NIF_TERM l = results, h;
    size_t i = 0;
    while (i < nresults && enif_get_list_cell(renv, l, &h, &l)) {
      if (!term_to_raw(renv, h, kind_of(rt->data[i]), &vals[i])) {
        fail = "result_type";
        break;
      }
      i++;
    }
    if (!fail && (i != nresults || !enif_is_empty_list(renv, l))) fail = "result_arity";
  }
  pthread_mutex_unlock(&inst->mu);
  return host_outcome(inst, fn, st, fail, NULL);
}

/* The same for imports with references in their signature: Wasmtime hands
 * over rooted arguments (it unroots them and the results afterwards). */
wasm_trap_t *host_callback_typed(void *envp, wasmtime_caller_t *caller, const wasmtime_val_t *args,
                                 size_t nargs, wasmtime_val_t *results, size_t nresults) {
  instance_t *inst = caller_inst(caller);
  hostfn_t *fn = &inst->wasm.entry->hostfns[(uintptr_t)envp];
  const wasm_valtype_vec_t *rt = wasm_functype_results(fn->type);
  const char *fail = NULL;

  ErlNifEnv *menv = enif_alloc_env();
  ERL_NIF_TERM list = enif_make_list(menv, 0);
  for (size_t i = nargs; i > 0; i--) {
    wasmtime_val_t copy;
    wasmtime_val_clone(&args[i - 1], &copy); /* the term takes this root over */
    ERL_NIF_TERM t = val_to_term(menv, inst, &copy);
    if (!t) {
      enif_free_env(menv);
      return wasmtime_trap_new("host function argument cannot cross the boundary", 47);
    }
    list = enif_make_list_cell(menv, t, list);
  }

  ERL_NIF_TERM rlist;
  enum host_status st = host_exchange(inst, fn, menv, list, &rlist, &fail);
  if (st == HOST_OK) {
    ErlNifEnv *renv = inst->host.reply_env;
    ERL_NIF_TERM l = rlist, h;
    size_t i = 0;
    while (i < nresults && enif_get_list_cell(renv, l, &h, &l)) {
      vtype_t t;
      vtype_of(rt->data[i], &t);
      if (term_to_val(renv, inst, h, &t, &results[i])) {
        fail = "result_type";
        break;
      }
      i++;
    }
    if (!fail && (i != nresults || !enif_is_empty_list(renv, l))) fail = "result_arity";
    if (fail) unroot_vals(results, i);
  }
  pthread_mutex_unlock(&inst->mu);
  return host_outcome(inst, fn, st, fail, NULL);
}
