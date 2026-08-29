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

static void set_host_failure(instance_t *inst, const char *msg, size_t len) {
  enif_free(inst->host.msg);
  inst->host.msg = enif_alloc(len + 1);
  memcpy(inst->host.msg, msg, len);
  inst->host.msg[len] = 0;
  inst->host.failed = 1;
}

/* How the request that just ran ended, in priority order. Consumes `e` and
 * `trap`. A trap raised by a host callback comes back from Wasmtime as an
 * error wrapping a backtrace; the instance flags tell the real cause. */
ERL_NIF_TERM outcome(instance_t *inst, ErlNifEnv *out, wasmtime_error_t *e, wasm_trap_t *trap,
                     const char *cls) {
  if (inst->interrupted_fired || inst->host.failed) {
    if (e) wasmtime_error_delete(e);
    if (trap) wasm_trap_delete(trap);
    if (inst->interrupted_fired) return mk_error_s(out, "trap", "interrupt", "interrupted");
    return mk_error_s(out, "host", "host_error", inst->host.msg ? inst->host.msg : "host error");
  }
  if (e) return error_to_term(out, e, cls);
  if (trap) return trap_to_term(out, trap);
  return atom_ok;
}

/* Runs on the instance thread, inside wasmtime_func_call. The mutex is not
 * held while the guest runs, so take it here. */
enum host_status { HOST_OK, HOST_INTERRUPTED, HOST_FAILED };

/* Sends {wasmtime_host_call, Ref, Id, {Module, Name}, Args} (`args` lives in
 * `menv`, consumed here) and waits for the reply. Returns with the mutex
 * held. On HOST_OK, *results is the reply's result list in inst->host.reply_env;
 * on HOST_FAILED, inst->host.failed is set or *fail names the reason. */
static enum host_status host_exchange(instance_t *inst, hostfn_t *fn, ErlNifEnv *menv,
                                      ERL_NIF_TERM args, ERL_NIF_TERM *results, const char **fail) {
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
    *fail = "host process is gone";
  } else {
    struct timespec deadline;
    add_ms(&deadline, inst->host.timeout_ms);
    while (!inst->host.has_reply && !inst->host.abort) {
      if (pthread_cond_timedwait(&inst->cv, &inst->mu, &deadline) == ETIMEDOUT) {
        if (!inst->host.has_reply && !inst->host.abort) *fail = "host function timed out";
        break;
      }
    }
    if (!*fail && inst->host.abort) interrupted = 1;
  }
  inst->queue.state = ST_RUNNING;
  if (interrupted) return HOST_INTERRUPTED;
  if (*fail) return HOST_FAILED;

  /* {ok, Results} | {error, Message :: binary()} */
  ErlNifEnv *renv = inst->host.reply_env;
  const ERL_NIF_TERM *tup;
  int arity;
  ErlNifBinary bin;
  if (!enif_get_tuple(renv, inst->host.reply, &arity, &tup) || arity != 2) {
    *fail = "host function returned a malformed reply";
    return HOST_FAILED;
  }
  if (enif_is_identical(tup[0], atom_error)) {
    if (!enif_inspect_iolist_as_binary(renv, tup[1], &bin)) {
      bin.data = (unsigned char *)"host error";
      bin.size = 10;
    }
    set_host_failure(inst, (const char *)bin.data, bin.size);
    return HOST_FAILED;
  }
  *results = tup[1];
  return HOST_OK;
}

/* After host_exchange, with the mutex released: the trap to return, if any. */
wasm_trap_t *host_outcome(instance_t *inst, enum host_status st, const char *fail) {
  if (st == HOST_INTERRUPTED) {
    inst->interrupted_fired = 1;
    return wasmtime_trap_new("interrupted", 11);
  }
  if (fail) set_host_failure(inst, fail, strlen(fail));
  if (inst->host.failed) return wasmtime_trap_new(inst->host.msg, strlen(inst->host.msg));
  return NULL;
}

/* Runs on the instance thread, inside wasmtime_func_call, for imports whose
 * signature has no references: values cross as wasmtime_val_raw_t. */
wasm_trap_t *host_callback(void *envp, wasmtime_caller_t *caller, wasmtime_val_raw_t *vals,
                           size_t nvals) {
  hostfn_env_t *he = envp;
  instance_t *inst = he->inst;
  hostfn_t *fn = &inst->wasm.hostfns[he->idx];
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
        fail = "host function returned a value of the wrong type";
        break;
      }
      i++;
    }
    if (!fail && (i != nresults || !enif_is_empty_list(renv, l)))
      fail = "host function returned the wrong number of values";
  }
  pthread_mutex_unlock(&inst->mu);
  return host_outcome(inst, st, fail);
}

/* The same for imports with references in their signature: Wasmtime hands
 * over rooted arguments (it unroots them and the results afterwards). */
wasm_trap_t *host_callback_typed(void *envp, wasmtime_caller_t *caller, const wasmtime_val_t *args,
                                 size_t nargs, wasmtime_val_t *results, size_t nresults) {
  hostfn_env_t *he = envp;
  instance_t *inst = he->inst;
  hostfn_t *fn = &inst->wasm.hostfns[he->idx];
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
        fail = "host function returned a value of the wrong type";
        break;
      }
      i++;
    }
    if (!fail && (i != nresults || !enif_is_empty_list(renv, l)))
      fail = "host function returned the wrong number of values";
    if (fail) unroot_vals(results, i);
  }
  pthread_mutex_unlock(&inst->mu);
  return host_outcome(inst, st, fail);
}
