/*
 * nif_instance.c: Instance lifetime and scheduling: the request queue, the
 * worker thread, the destructors and monitors, and the guards that give a
 * scheduler thread the store while the guest is not running.
 */
#include "nif.h"

ErlNifResourceType *module_type, *instance_type, *handle_type, *ref_type;

static void req_free(req_t *r) {
  if (r->env) enif_free_env(r->env);
  enif_free(r);
}

/* Build and send {wasmtime_result, Ref, Id, Result}. `env` owns `result`. */
static void send_result(instance_t *inst, req_t *req, ErlNifEnv *env, ERL_NIF_TERM result) {
  ERL_NIF_TERM msg = enif_make_tuple4(env, atom_wasmtime_result, enif_make_copy(env, inst->ref),
                                      enif_make_uint64(env, req->id), result);
  enif_send(NULL, &req->caller, env, msg);
}

wasmtime_error_t *epoch_callback(wasmtime_context_t *ctx, void *data, uint64_t *delta,
                                 wasmtime_update_deadline_kind_t *kind) {
  instance_t *inst = data;
  if (__atomic_load_n(&inst->interrupt, __ATOMIC_ACQUIRE)) {
    inst->interrupted_fired = 1;
    return wasmtime_error_new("interrupted");
  }
  *delta = 1;
  *kind = WASMTIME_UPDATE_DEADLINE_CONTINUE;
  return NULL;
}

/* Called with the mutex held. Removes the request's monitor and frees it. */
static void req_done(instance_t *inst, req_t *req) {
  if (req->monitored) enif_demonitor_process(NULL, inst, &req->mon);
  req_free(req);
}

void *worker_main(void *arg) {
  instance_t *inst = arg;
  pthread_mutex_lock(&inst->mu);
  while (!inst->queue.stopping) {
    if (!inst->queue.head) {
      pthread_cond_wait(&inst->cv, &inst->mu);
      continue;
    }
    req_t *req = inst->queue.head;
    inst->queue.head = req->next;
    if (!inst->queue.head) inst->queue.tail = NULL;
    if (req->cancelled) {
      req_done(inst, req);
      continue;
    }
    inst->queue.current = req;
    inst->queue.state = ST_RUNNING;
    inst->host.abort = 0;
    inst->interrupted_fired = 0;
    inst->host.failed = 0;
    __atomic_store_n(&inst->interrupt, 0, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&inst->mu);

    ErlNifEnv *out = enif_alloc_env();
    ERL_NIF_TERM result =
        req->kind == REQ_INSTANTIATE ? do_instantiate(inst, req, out) : do_call(inst, req, out);

    pthread_mutex_lock(&inst->mu);
    inst->queue.state = ST_IDLE;
    inst->queue.current = NULL;
    if (!req->cancelled) send_result(inst, req, out, result);
    enif_free_env(out);
    int failed_instantiate = req->kind == REQ_INSTANTIATE && !inst->wasm.instantiated;
    req_done(inst, req);
    if (failed_instantiate) inst->queue.stopping = 1;
  }
  /* Nothing more runs. Tell whoever is still waiting. */
  while (inst->queue.head) {
    req_t *req = inst->queue.head;
    inst->queue.head = req->next;
    if (!req->cancelled) {
      ErlNifEnv *out = enif_alloc_env();
      send_result(inst, req, out, mk_error_s(out, "call", "stopped", "instance is stopped"));
      enif_free_env(out);
    }
    req_done(inst, req);
  }
  inst->queue.tail = NULL;
  pthread_mutex_unlock(&inst->mu);
  /* The thread's own reference; nothing below may touch `inst`. */
  enif_release_resource(inst);
  return NULL;
}

void module_dtor(ErlNifEnv *env, void *obj) {
  module_res_t *m = obj;
  if (m->mod) wasmtime_module_delete(m->mod);
}

/* Runs once the handle and the worker thread have both let go: the thread
 * has exited (or never started), so nothing else can be using the instance. */
void instance_dtor(ErlNifEnv *env, void *obj) {
  instance_t *inst = obj;
  while (inst->queue.head) {
    req_t *r = inst->queue.head;
    inst->queue.head = r->next;
    req_free(r);
  }
  if (inst->wasm.linker) wasmtime_linker_delete(inst->wasm.linker);
  if (inst->wasm.store) wasmtime_store_delete(inst->wasm.store);
  for (size_t i = 0; i < inst->wasm.nhostfns; i++) {
    enif_free(inst->wasm.hostfns[i].module);
    enif_free(inst->wasm.hostfns[i].name);
    wasm_functype_delete(inst->wasm.hostfns[i].type);
  }
  enif_free(inst->wasm.hostfns);
  if (inst->host.reply_env) enif_free_env(inst->host.reply_env);
  if (inst->ref_env) enif_free_env(inst->ref_env);
  enif_free(inst->capture.buf[0].data);
  enif_free(inst->capture.buf[1].data);
  while (inst->inbox.head) inbox_drop_head(inst);
  enif_free(inst->host.msg);
  if (inst->wasm.mod) enif_release_resource(inst->wasm.mod);
  pthread_mutex_destroy(&inst->mu);
  pthread_cond_destroy(&inst->cv);
}

/* Ask the running request to end. Called with the mutex held. */
void stop_current(instance_t *inst) {
  inst->host.abort = 1;
  __atomic_store_n(&inst->interrupt, 1, __ATOMIC_RELEASE);
  pthread_cond_broadcast(&inst->cv);
}

/* Erlang dropped its last reference: stop the thread, never wait for it. */
void handle_dtor(ErlNifEnv *env, void *obj) {
  handle_t *h = obj;
  instance_t *inst = h->inst;
  if (!inst) return;
  pthread_mutex_lock(&inst->mu);
  inst->queue.stopping = 1;
  if (inst->queue.current) inst->queue.current->cancelled = 1;
  stop_current(inst);
  pthread_mutex_unlock(&inst->mu);
  enif_release_resource(inst);
}

/* A process with a request on this instance died. Its running request is
 * interrupted and its queued requests are dropped before they start. */
void instance_down(ErlNifEnv *env, void *obj, ErlNifPid *pid, ErlNifMonitor *mon) {
  instance_t *inst = obj;
  pthread_mutex_lock(&inst->mu);
  if (inst->queue.current && enif_compare_pids(&inst->queue.current->caller, pid) == 0) {
    inst->queue.current->cancelled = 1;
    stop_current(inst);
  }
  for (req_t *r = inst->queue.head; r; r = r->next)
    if (enif_compare_pids(&r->caller, pid) == 0) r->cancelled = 1;
  pthread_mutex_unlock(&inst->mu);
}

int get_handle(ErlNifEnv *env, ERL_NIF_TERM t, instance_t **out) {
  handle_t *h;
  if (!enif_get_resource(env, t, handle_type, (void **)&h)) return 0;
  *out = h->inst;
  return 1;
}

/* Enqueue a request for the instance thread. Called on a scheduler thread. */
ERL_NIF_TERM enqueue(ErlNifEnv *env, instance_t *inst, enum req_kind kind, ERL_NIF_TERM id,
                     ERL_NIF_TERM name, ERL_NIF_TERM args, ERL_NIF_TERM opts) {
  req_t *r = enif_alloc(sizeof *r);
  memset(r, 0, sizeof *r);
  r->kind = kind;
  if (!enif_get_uint64(env, id, &r->id)) {
    enif_free(r);
    return enif_make_badarg(env);
  }
  enif_self(env, &r->caller);
  r->env = enif_alloc_env();
  r->name = enif_make_copy(r->env, name);
  r->args = enif_make_copy(r->env, args);
  r->opts = enif_make_copy(r->env, opts);

  pthread_mutex_lock(&inst->mu);
  if (inst->queue.stopping) {
    pthread_mutex_unlock(&inst->mu);
    req_free(r);
    return mk_error_s(env, "call", "stopped", "instance is stopped");
  }
  /* A host function calling back into the instance it runs on would wait for
   * itself: the guest is parked until this process answers the host call. */
  if (inst->queue.state == ST_IN_HOST && enif_compare_pids(&inst->host.target, &r->caller) == 0) {
    pthread_mutex_unlock(&inst->mu);
    req_free(r);
    return mk_error_s(env, "call", "reentrant",
                      "a host function cannot call the instance it is running on");
  }
  r->monitored = enif_monitor_process(env, inst, &r->caller, &r->mon) == 0;
  if (inst->queue.tail)
    inst->queue.tail->next = r;
  else
    inst->queue.head = r;
  inst->queue.tail = r;
  pthread_cond_broadcast(&inst->cv);
  pthread_mutex_unlock(&inst->mu);
  return atom_enqueued;
}

/* Look up an export of a given kind while the guest is not executing. On
 * success the caller holds inst->mu. */
ERL_NIF_TERM with_export(ErlNifEnv *env, ERL_NIF_TERM handle, ERL_NIF_TERM name,
                         wasmtime_extern_kind_t kind, const char *what, instance_t **out,
                         wasmtime_extern_t *ext) {
  instance_t *inst;
  ErlNifBinary nm;
  if (!get_handle(env, handle, &inst) || !enif_inspect_iolist_as_binary(env, name, &nm))
    return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  if (inst->queue.state == ST_RUNNING) {
    pthread_mutex_unlock(&inst->mu);
    return mk_error_s(env, what, "busy", "guest is running");
  }
  if (!inst->wasm.instantiated ||
      !wasmtime_instance_export_get(inst->wasm.ctx, &inst->wasm.instance, (const char *)nm.data,
                                    nm.size, ext) ||
      ext->kind != kind) {
    pthread_mutex_unlock(&inst->mu);
    return mk_error(env, what, "no_such_export", (const char *)nm.data, nm.size);
  }
  *out = inst;
  return 0;
}

/* Locks the instance a reference belongs to, like with_export. */
ERL_NIF_TERM with_ref(ErlNifEnv *env, ERL_NIF_TERM term, ref_t **out) {
  ref_t *r;
  if (!enif_get_resource(env, term, ref_type, (void **)&r)) return enif_make_badarg(env);
  pthread_mutex_lock(&r->inst->mu);
  if (r->inst->queue.state == ST_RUNNING) {
    pthread_mutex_unlock(&r->inst->mu);
    return mk_error_s(env, "ref", "busy", "guest is running");
  }
  *out = r;
  return 0;
}

/* Memory is reachable from Erlang only while the guest is not executing:
 * when the instance is idle, or while it waits inside a host function. On
 * success the caller holds inst->mu and *mem names the memory: the default
 * one when `name` is the atom `default`, else the export called `name`. */
ERL_NIF_TERM with_memory(ErlNifEnv *env, ERL_NIF_TERM handle, ERL_NIF_TERM name, instance_t **out,
                         wasmtime_memory_t *mem) {
  instance_t *inst;
  ErlNifBinary nm;
  int named = !enif_is_atom(env, name);
  if (!get_handle(env, handle, &inst) || (named && !enif_inspect_iolist_as_binary(env, name, &nm)))
    return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  if (inst->queue.state == ST_RUNNING) {
    pthread_mutex_unlock(&inst->mu);
    return mk_error_s(env, "memory", "busy", "guest is running");
  }
  if (!inst->wasm.instantiated) {
    pthread_mutex_unlock(&inst->mu);
    return mk_error_s(env, "memory", "no_memory", "instance exports no memory");
  }
  if (named) {
    wasmtime_extern_t ext;
    if (!wasmtime_instance_export_get(inst->wasm.ctx, &inst->wasm.instance, (const char *)nm.data,
                                      nm.size, &ext) ||
        ext.kind != WASMTIME_EXTERN_MEMORY) {
      pthread_mutex_unlock(&inst->mu);
      return mk_error(env, "memory", "no_memory", (const char *)nm.data, nm.size);
    }
    *mem = ext.of.memory;
  } else if (inst->wasm.has_memory) {
    *mem = inst->wasm.memory;
  } else {
    pthread_mutex_unlock(&inst->mu);
    return mk_error_s(env, "memory", "no_memory", "instance exports no memory");
  }
  *out = inst;
  return 0;
}
