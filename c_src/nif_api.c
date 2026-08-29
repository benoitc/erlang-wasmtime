/*
 * nif_api.c: NIF entry points that are not owned by another file, the function
 * table, load and unload.
 */
#include "nif.h"

static ERL_NIF_TERM nif_compile(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
  int is_wat = enif_is_identical(argv[1], atom_true);
#if !NIF_HAVE_COMPILER
  (void)is_wat;
  return mk_error_s(env, "compile", "unavailable",
                    "this build of erlang_wasmtime has no compiler: use deserialize/1");
#else
  wasm_byte_vec_t wasm = {0, NULL};
  const uint8_t *data = bin.data;
  size_t size = bin.size;
  if (is_wat) {
#if !NIF_HAVE_WAT
    return mk_error_s(env, "compile", "unavailable",
                      "this build of erlang_wasmtime cannot read the text format");
#else
    wasmtime_error_t *e = wasmtime_wat2wasm((const char *)bin.data, bin.size, &wasm);
    if (e) return error_to_term(env, e, "compile");
    data = (const uint8_t *)wasm.data;
    size = wasm.size;
#endif
  }
  ERL_NIF_TERM err;
  engine_t *eng = engine_for(env, argv[2], &err);
  if (!eng) {
    if (is_wat) wasm_byte_vec_delete(&wasm);
    return err;
  }
  wasmtime_module_t *mod = NULL;
  wasmtime_error_t *e = wasmtime_module_new(eng->engine, data, size, &mod);
  if (is_wat) wasm_byte_vec_delete(&wasm);
  if (e) return error_to_term(env, e, "compile");
  module_res_t *m = enif_alloc_resource(module_type, sizeof *m);
  m->mod = mod;
  m->engine = eng;
  ERL_NIF_TERM t = enif_make_resource(env, m);
  enif_release_resource(m);
  return enif_make_tuple2(env, atom_ok, t);
#endif
}

/* module_options(Module) -> the engine key it was compiled or loaded with */
static ERL_NIF_TERM nif_module_options(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  module_res_t *m;
  if (!enif_get_resource(env, argv[0], module_type, (void **)&m)) return enif_make_badarg(env);
  return key_term(env, m->engine);
}

/* validate(Binary, Key) -> ok | {error, _}: decode and validate without compiling */
static ERL_NIF_TERM nif_validate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
#if !NIF_HAVE_COMPILER
  return mk_error_s(env, "compile", "unavailable", "this build of erlang_wasmtime cannot validate");
#else
  ERL_NIF_TERM err;
  engine_t *eng = engine_for(env, argv[1], &err);
  if (!eng) return err;
  wasmtime_error_t *e = wasmtime_module_validate(eng->engine, bin.data, bin.size);
  if (e) return error_to_term(env, e, "compile");
  return atom_ok;
#endif
}

/* serialize(Module) -> {ok, Binary}: Wasmtime's own precompiled format */
static ERL_NIF_TERM nif_serialize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  module_res_t *m;
  if (!enif_get_resource(env, argv[0], module_type, (void **)&m)) return enif_make_badarg(env);
#if !NIF_HAVE_COMPILER
  return mk_error_s(env, "compile", "unavailable",
                    "this build of erlang_wasmtime cannot serialize modules");
#else
  wasm_byte_vec_t out;
  wasmtime_error_t *e = wasmtime_module_serialize(m->mod, &out);
  if (e) return error_to_term(env, e, "compile");
  ERL_NIF_TERM t = mk_binary(env, out.data, out.size);
  wasm_byte_vec_delete(&out);
  return enif_make_tuple2(env, atom_ok, t);
#endif
}

/* deserialize(Binary) -> {ok, Module}. Wasmtime checks its own version and
 * the CPU features the code was compiled for, not the code itself: only
 * bytes that came from serialize/1 may be passed here. */
static ERL_NIF_TERM nif_deserialize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifBinary bin;
  if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
  wasmtime_module_t *mod = NULL;
  ERL_NIF_TERM err;
  engine_t *eng;
  wasmtime_error_t *e;
  if (enif_is_identical(argv[1], atom_undefined)) {
    /* deserialize/1: the default engine, then the fuel engine */
    ERL_NIF_TERM plain =
        enif_make_tuple3(env, atom_false, mk_atom(env, "speed"), enif_make_list(env, 0));
    eng = engine_for(env, plain, &err);
    if (!eng) return err;
    e = wasmtime_module_deserialize(eng->engine, bin.data, bin.size, &mod);
    if (e) {
      ERL_NIF_TERM fuel =
          enif_make_tuple3(env, atom_true, mk_atom(env, "speed"), enif_make_list(env, 0));
      engine_t *feng = engine_for(env, fuel, &err);
      if (!feng) {
        wasmtime_error_delete(e);
        return err;
      }
      wasmtime_error_t *e2 = wasmtime_module_deserialize(feng->engine, bin.data, bin.size, &mod);
      if (e2) {
        wasmtime_error_delete(e2);
        return error_to_term(env, e, "compile");
      }
      wasmtime_error_delete(e);
      eng = feng;
    }
  } else {
    eng = engine_for(env, argv[1], &err);
    if (!eng) return err;
    e = wasmtime_module_deserialize(eng->engine, bin.data, bin.size, &mod);
    if (e) return error_to_term(env, e, "compile");
  }
  module_res_t *m = enif_alloc_resource(module_type, sizeof *m);
  m->mod = mod;
  m->engine = eng;
  ERL_NIF_TERM t = enif_make_resource(env, m);
  enif_release_resource(m);
  return enif_make_tuple2(env, atom_ok, t);
}

static ERL_NIF_TERM extern_kind_atom(wasm_externkind_t k) {
  switch (k) {
  case WASM_EXTERN_FUNC: return atom_func;
  case WASM_EXTERN_GLOBAL: return atom_global;
  case WASM_EXTERN_TABLE: return atom_table;
  case WASM_EXTERN_MEMORY: return atom_memory;
  default: return atom_tag; /* WASM_EXTERN_TAG, the last kind in wasm.h */
  }
}

static ERL_NIF_TERM nif_module_imports(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  module_res_t *m;
  if (!enif_get_resource(env, argv[0], module_type, (void **)&m)) return enif_make_badarg(env);
  wasm_importtype_vec_t v;
  wasmtime_module_imports(m->mod, &v);
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (size_t i = v.size; i > 0; i--) {
    const wasm_importtype_t *it = v.data[i - 1];
    const wasm_name_t *mn = wasm_importtype_module(it), *nn = wasm_importtype_name(it);
    list = enif_make_list_cell(
        env,
        enif_make_tuple3(env, mk_binary(env, mn->data, mn->size),
                         mk_binary(env, nn->data, nn->size),
                         extern_kind_atom(wasm_externtype_kind(wasm_importtype_type(it)))),
        list);
  }
  wasm_importtype_vec_delete(&v);
  return list;
}

static ERL_NIF_TERM nif_module_exports(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  module_res_t *m;
  if (!enif_get_resource(env, argv[0], module_type, (void **)&m)) return enif_make_badarg(env);
  wasm_exporttype_vec_t v;
  wasmtime_module_exports(m->mod, &v);
  ERL_NIF_TERM list = enif_make_list(env, 0);
  for (size_t i = v.size; i > 0; i--) {
    const wasm_exporttype_t *et = v.data[i - 1];
    const wasm_name_t *nn = wasm_exporttype_name(et);
    list = enif_make_list_cell(
        env,
        enif_make_tuple2(env, mk_binary(env, nn->data, nn->size),
                         extern_kind_atom(wasm_externtype_kind(wasm_exporttype_type(et)))),
        list);
  }
  wasm_exporttype_vec_delete(&v);
  return list;
}

/* instantiate(Module, Opts, Ref, Id) -> {ok, Handle}; result arrives as a message */
static ERL_NIF_TERM nif_instantiate(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  module_res_t *m;
  if (!enif_get_resource(env, argv[0], module_type, (void **)&m) || !enif_is_ref(env, argv[2]))
    return enif_make_badarg(env);

  instance_t *inst = enif_alloc_resource(instance_type, sizeof *inst);
  memset(inst, 0, sizeof *inst);
  pthread_mutex_init(&inst->mu, NULL);
  pthread_cond_init(&inst->cv, NULL);
  inst->reply_env = enif_alloc_env();
  inst->ref_env = enif_alloc_env();
  inst->ref = enif_make_copy(inst->ref_env, argv[2]);
  inst->mod = m;
  enif_keep_resource(m);
  inst->host_timeout_ms = 30000;

  /* The handle holds one reference to the instance, the thread the other
   * (the one enif_alloc_resource returned). */
  handle_t *h = enif_alloc_resource(handle_type, sizeof *h);
  h->inst = inst;
  enif_keep_resource(inst);
  ERL_NIF_TERM ht = enif_make_resource(env, h);
  enif_release_resource(h);

  ERL_NIF_TERM r =
      enqueue(env, inst, REQ_INSTANTIATE, argv[3], atom_undefined, atom_undefined, argv[1]);
  if (!enif_is_identical(r, atom_enqueued)) {
    enif_release_resource(inst);
    return r;
  }
  /* Wasmtime runs the guest on the native stack (max_wasm_stack, 512 KB by
   * default) and our callback runs above it; the platform default for a new
   * thread is 512 KB on macOS. Ask for a size that holds both everywhere. */
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  pthread_attr_setstacksize(&attr, 4 * 1024 * 1024);
  pthread_t tid;
  int rc = pthread_create(&tid, &attr, worker_main, inst);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    pthread_mutex_lock(&inst->mu);
    inst->stopping = 1;
    pthread_mutex_unlock(&inst->mu);
    enif_release_resource(inst); /* the thread's reference, never taken */
    return mk_error_s(env, "link", "thread", "could not start instance thread");
  }
  return enif_make_tuple2(env, atom_ok, ht);
}

/* call(Handle, Name, Args, Id, Fuel | undefined) -> enqueued; result arrives as a message */
static ERL_NIF_TERM nif_call(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst) || !enif_is_list(env, argv[2])) return enif_make_badarg(env);
  return enqueue(env, inst, REQ_CALL, argv[3], argv[1], argv[2], argv[4]);
}

/* global_get(Handle, Name) -> {ok, Value} */
static ERL_NIF_TERM nif_global_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_GLOBAL, "global", &inst, &ext);
  if (err) return err;
  wasmtime_val_t v;
  wasmtime_global_get(inst->ctx, &ext.of.global, &v);
  ERL_NIF_TERM r = term_or_unsupported(env, "global", val_to_term(env, inst, &v));
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* global_set(Handle, Name, Value) -> ok */
static ERL_NIF_TERM nif_global_set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_GLOBAL, "global", &inst, &ext);
  if (err) return err;
  wasm_globaltype_t *gt = wasmtime_global_type(inst->ctx, &ext.of.global);
  ERL_NIF_TERM r;
  wasmtime_val_t v;
  vtype_t t;
  vtype_of(wasm_globaltype_content(gt), &t);
  const char *kind;
  if (wasm_globaltype_mutability(gt) == WASM_CONST) {
    r = mk_error_s(env, "global", "immutable", "the global is not mutable");
  } else if ((kind = term_to_val(env, inst, argv[2], &t, &v))) {
    r = conv_error(env, "global", kind);
  } else {
    wasmtime_error_t *e = wasmtime_global_set(inst->ctx, &ext.of.global, &v);
    wasmtime_val_unroot(&v);
    r = e ? error_to_term(env, e, "global") : atom_ok;
  }
  wasm_globaltype_delete(gt);
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* table_size(Handle, Name) -> {ok, Elements} */
static ERL_NIF_TERM nif_table_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_TABLE, "table", &inst, &ext);
  if (err) return err;
  ERL_NIF_TERM r = enif_make_tuple2(
      env, atom_ok, enif_make_uint64(env, wasmtime_table_size(inst->ctx, &ext.of.table)));
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* table_get(Handle, Name, Index) -> {ok, Value} */
static ERL_NIF_TERM nif_table_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 index;
  if (!enif_get_uint64(env, argv[2], &index)) return enif_make_badarg(env);
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_TABLE, "table", &inst, &ext);
  if (err) return err;
  wasmtime_val_t v;
  ERL_NIF_TERM r;
  if (!wasmtime_table_get(inst->ctx, &ext.of.table, index, &v))
    r = mk_error_s(env, "table", "out_of_bounds", "index is past the table's size");
  else
    r = term_or_unsupported(env, "table", val_to_term(env, inst, &v));
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* The element type of a table, as the boundary sees it. */
static void table_elem_type(instance_t *inst, const wasmtime_table_t *table, vtype_t *t) {
  wasm_tabletype_t *tt = wasmtime_table_type(inst->ctx, table);
  vtype_of(wasm_tabletype_element(tt), t);
  wasm_tabletype_delete(tt);
}

/* table_set(Handle, Name, Index, Value) -> ok */
static ERL_NIF_TERM nif_table_set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 index;
  if (!enif_get_uint64(env, argv[2], &index)) return enif_make_badarg(env);
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_TABLE, "table", &inst, &ext);
  if (err) return err;
  vtype_t t;
  table_elem_type(inst, &ext.of.table, &t);
  wasmtime_val_t v;
  ERL_NIF_TERM r;
  const char *kind = term_to_val(env, inst, argv[3], &t, &v);
  if (kind) {
    r = conv_error(env, "table", kind);
  } else {
    wasmtime_error_t *e = wasmtime_table_set(inst->ctx, &ext.of.table, index, &v);
    wasmtime_val_unroot(&v);
    r = e ? error_to_term(env, e, "table") : atom_ok;
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* table_grow(Handle, Name, Delta, Init) -> {ok, PreviousSize} */
static ERL_NIF_TERM nif_table_grow(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 delta;
  if (!enif_get_uint64(env, argv[2], &delta)) return enif_make_badarg(env);
  instance_t *inst;
  wasmtime_extern_t ext;
  ERL_NIF_TERM err =
      with_export(env, argv[0], argv[1], WASMTIME_EXTERN_TABLE, "table", &inst, &ext);
  if (err) return err;
  vtype_t t;
  table_elem_type(inst, &ext.of.table, &t);
  wasmtime_val_t init;
  ERL_NIF_TERM r;
  const char *kind = term_to_val(env, inst, argv[3], &t, &init);
  if (kind) {
    r = conv_error(env, "table", kind);
  } else {
    uint64_t prev = 0;
    wasmtime_error_t *e = wasmtime_table_grow(inst->ctx, &ext.of.table, delta, &init, &prev);
    wasmtime_val_unroot(&init);
    r = e ? error_to_term(env, e, "table")
          : enif_make_tuple2(env, atom_ok, enif_make_uint64(env, prev));
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* fuel_remaining(Handle) -> {ok, Fuel} */ /* fuel_remaining(Handle) -> {ok, Fuel} */
static ERL_NIF_TERM nif_fuel_remaining(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst)) return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r;
  uint64_t fuel = 0;
  if (inst->state == ST_RUNNING) {
    r = mk_error_s(env, "call", "busy", "guest is running");
  } else if (!inst->instantiated || !inst->mod->engine->fuel) {
    r = mk_error_s(env, "call", "fuel_disabled",
                   "the module was not compiled with fuel metering: compile with fuel => true");
  } else {
    wasmtime_error_t *e = wasmtime_context_get_fuel(inst->ctx, &fuel);
    r = e ? error_to_term(env, e, "call")
          : enif_make_tuple2(env, atom_ok, enif_make_uint64(env, fuel));
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* host_reply(Handle, HostId, {ok, Results} | {error, Message}) -> ok */
static ERL_NIF_TERM nif_host_reply(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  ErlNifUInt64 id;
  if (!get_handle(env, argv[0], &inst) || !enif_get_uint64(env, argv[1], &id))
    return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r;
  if (inst->state == ST_IN_HOST && inst->host_id == id && !inst->has_reply) {
    inst->reply = enif_make_copy(inst->reply_env, argv[2]);
    inst->has_reply = 1;
    pthread_cond_broadcast(&inst->cv);
    r = atom_ok;
  } else {
    r = enif_make_tuple2(env, atom_error, atom_no_pending_host_call);
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* interrupt(Handle) -> ok | not_running: end whatever runs, keep its result */
static ERL_NIF_TERM nif_interrupt(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst)) return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r = atom_not_running;
  if (inst->current) {
    stop_current(inst);
    r = atom_ok;
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* cancel(Handle, Id) -> ok | not_running: end request Id and drop its result.
 * `ok` means no result message will follow; `not_running` means the request
 * already finished and its result is in the caller's mailbox. */
static ERL_NIF_TERM nif_cancel(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  ErlNifUInt64 id;
  if (!get_handle(env, argv[0], &inst) || !enif_get_uint64(env, argv[1], &id))
    return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r = atom_not_running;
  if (inst->current && inst->current->id == id) {
    inst->current->cancelled = 1;
    stop_current(inst);
    r = atom_ok;
  } else {
    for (req_t *q = inst->head; q; q = q->next) {
      if (q->id == id) {
        q->cancelled = 1;
        r = atom_ok;
        break;
      }
    }
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* read_memory(Handle, Name | default, Ptr, Len) */
static ERL_NIF_TERM nif_read_memory(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 ptr, len;
  if (!enif_get_uint64(env, argv[2], &ptr) || !enif_get_uint64(env, argv[3], &len))
    return enif_make_badarg(env);
  instance_t *inst;
  wasmtime_memory_t mem;
  ERL_NIF_TERM err = with_memory(env, argv[0], argv[1], &inst, &mem);
  if (err) return err;
  size_t size = wasmtime_memory_data_size(inst->ctx, &mem);
  ERL_NIF_TERM r;
  if (ptr > size || len > size - ptr) {
    r = mk_error_s(env, "memory", "out_of_bounds", "range is outside linear memory");
  } else {
    const uint8_t *data = wasmtime_memory_data(inst->ctx, &mem);
    r = enif_make_tuple2(env, atom_ok, mk_binary(env, data + ptr, len));
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* write_memory(Handle, Name | default, Ptr, Data) */
static ERL_NIF_TERM nif_write_memory(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 ptr;
  ErlNifBinary bin;
  if (!enif_get_uint64(env, argv[2], &ptr) || !enif_inspect_iolist_as_binary(env, argv[3], &bin))
    return enif_make_badarg(env);
  instance_t *inst;
  wasmtime_memory_t mem;
  ERL_NIF_TERM err = with_memory(env, argv[0], argv[1], &inst, &mem);
  if (err) return err;
  size_t size = wasmtime_memory_data_size(inst->ctx, &mem);
  ERL_NIF_TERM r;
  if (ptr > size || bin.size > size - ptr) {
    r = mk_error_s(env, "memory", "out_of_bounds", "range is outside linear memory");
  } else {
    memcpy(wasmtime_memory_data(inst->ctx, &mem) + ptr, bin.data, bin.size);
    r = atom_ok;
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* memory_size(Handle, Name | default) */
static ERL_NIF_TERM nif_memory_size(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  wasmtime_memory_t mem;
  ERL_NIF_TERM err = with_memory(env, argv[0], argv[1], &inst, &mem);
  if (err) return err;
  ERL_NIF_TERM r = enif_make_tuple2(
      env, atom_ok,
      enif_make_tuple2(env, enif_make_uint64(env, wasmtime_memory_size(inst->ctx, &mem)),
                       enif_make_uint64(env, wasmtime_memory_data_size(inst->ctx, &mem))));
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* read_output(Handle) -> {ok, {Stdout, Stderr, {DroppedOut, DroppedErr}}}: takes what
 * the captured streams hold and empties them; safe while the guest runs. */
static ERL_NIF_TERM nif_read_output(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst)) return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM out = mk_binary(env, inst->capture[0].data, inst->capture[0].len);
  ERL_NIF_TERM err = mk_binary(env, inst->capture[1].data, inst->capture[1].len);
  ERL_NIF_TERM dropped = enif_make_tuple2(env, enif_make_uint64(env, inst->dropped[0]),
                                          enif_make_uint64(env, inst->dropped[1]));
  inst->capture[0].len = inst->capture[1].len = 0;
  inst->dropped[0] = inst->dropped[1] = 0;
  pthread_mutex_unlock(&inst->mu);
  return enif_make_tuple2(env, atom_ok, enif_make_tuple3(env, out, err, dropped));
}

/* features() -> #{compiler => bool, wat => bool, wasi => bool} */
static ERL_NIF_TERM nif_features(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ERL_NIF_TERM keys[3] = {atom_compiler, atom_wat, atom_wasi};
  ERL_NIF_TERM vals[3] = {NIF_HAVE_COMPILER ? atom_true : atom_false,
                          NIF_HAVE_WAT ? atom_true : atom_false,
                          NIF_HAVE_WASI ? atom_true : atom_false};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, 3, &map);
  return map;
}

static ERL_NIF_TERM nif_version(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  return mk_binary(env, WASMTIME_VERSION, strlen(WASMTIME_VERSION));
}

static int load(ErlNifEnv *env, void **priv, ERL_NIF_TERM info) {
#define A(name, str) name = enif_make_atom(env, str)
  A(atom_ok, "ok");
  A(atom_error, "error");
  A(atom_true, "true");
  A(atom_false, "false");
  A(atom_compiler, "compiler");
  A(atom_wat, "wat");
  A(atom_wasi, "wasi");
  A(atom_none, "none");
  A(atom_trace, "trace");
  A(atom_func_index, "func_index");
  A(atom_func_offset, "func_offset");
  A(atom_func_name, "func_name");
  A(atom_module_name, "module_name");
  A(atom_immutable, "immutable");
  A(atom_capture, "capture");
  A(atom_binary, "binary");
  A(atom_undefined, "undefined");
  A(atom_inherit, "inherit");
  A(atom_file, "file");
  A(atom_read, "read");
  A(atom_write, "write");
  A(atom_nan, "nan");
  A(atom_infinity, "infinity");
  A(atom_neg_infinity, "neg_infinity");
  A(atom_class, "class");
  A(atom_kind, "kind");
  A(atom_message, "message");
  A(atom_status, "status");
  A(atom_not_running, "not_running");
  A(atom_func, "func");
  A(atom_global, "global");
  A(atom_table, "table");
  A(atom_memory, "memory");
  A(atom_tag, "tag");
  A(atom_wasmtime_result, "wasmtime_result");
  A(atom_wasmtime_host_call, "wasmtime_host_call");
  A(atom_no_pending_host_call, "no_pending_host_call");
  A(atom_enqueued, "enqueued");
  A(atom_stream, "stream");
  A(atom_wasmtime_stream, "wasmtime_stream");
  A(atom_stdout, "stdout");
  A(atom_stderr, "stderr");
  A(atom_channel, "channel");
  A(atom_null, "null");
  A(atom_i31, "i31");
  A(atom_externref, "externref");
  A(atom_funcref, "funcref");
  A(atom_struct, "struct");
  A(atom_array, "array");
  A(atom_anyref, "anyref");
  A(atom_instance, "instance");
#undef A

  ErlNifResourceTypeInit mi = {.dtor = module_dtor};
  ErlNifResourceTypeInit ii = {.dtor = instance_dtor, .down = instance_down};
  ErlNifResourceTypeInit hi = {.dtor = handle_dtor};
  ErlNifResourceTypeInit ri = {.dtor = ref_dtor};
  module_type = enif_open_resource_type_x(env, "wasmtime_module", &mi, ERL_NIF_RT_CREATE, NULL);
  instance_type = enif_open_resource_type_x(env, "wasmtime_instance", &ii, ERL_NIF_RT_CREATE, NULL);
  handle_type = enif_open_resource_type_x(env, "wasmtime_handle", &hi, ERL_NIF_RT_CREATE, NULL);
  ref_type = enif_open_resource_type_x(env, "wasmtime_ref", &ri, ERL_NIF_RT_CREATE, NULL);
  if (!module_type || !instance_type || !handle_type || !ref_type) return -1;

  /* The default engine exists from the start; others come on first use. */
  ERL_NIF_TERM err;
  ERL_NIF_TERM plain =
      enif_make_tuple3(env, atom_false, mk_atom(env, "speed"), enif_make_list(env, 0));
  if (!engine_for(env, plain, &err)) return -1;
  if (!ticker_start()) return -1;
  return 0;
}

static void unload(ErlNifEnv *env, void *priv) {
  ticker_shutdown();
  engines_free_all();
}

static ErlNifFunc funcs[] = {
    {"compile", 3, nif_compile, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"validate", 2, nif_validate, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"module_options", 1, nif_module_options, 0},
    {"module_imports", 1, nif_module_imports, 0},
    {"module_exports", 1, nif_module_exports, 0},
    {"serialize", 1, nif_serialize, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"deserialize", 2, nif_deserialize, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"instantiate", 4, nif_instantiate, 0},
    {"call", 5, nif_call, 0},
    {"global_get", 2, nif_global_get, 0},
    {"global_set", 3, nif_global_set, 0},
    {"table_size", 2, nif_table_size, 0},
    {"table_get", 3, nif_table_get, 0},
    {"table_set", 4, nif_table_set, 0},
    {"table_grow", 4, nif_table_grow, 0},
    {"ref_info", 1, nif_ref_info, 0},
    {"externref", 2, nif_externref, 0},
    {"externref_data", 1, nif_externref_data, 0},
    {"struct_get", 2, nif_struct_get, 0},
    {"struct_set", 3, nif_struct_set, 0},
    {"array_len", 1, nif_array_len, 0},
    {"array_get", 2, nif_array_get, 0},
    {"array_set", 3, nif_array_set, 0},
    {"gc", 1, nif_gc, 0},
    {"fuel_remaining", 1, nif_fuel_remaining, 0},
    {"host_reply", 3, nif_host_reply, 0},
    {"send", 2, nif_send, 0},
    {"close", 1, nif_close, 0},
    {"interrupt", 1, nif_interrupt, 0},
    {"cancel", 2, nif_cancel, 0},
    {"read_memory", 4, nif_read_memory, 0},
    {"write_memory", 4, nif_write_memory, 0},
    {"memory_size", 2, nif_memory_size, 0},
    {"read_output", 1, nif_read_output, 0},
    {"features", 0, nif_features, 0},
    {"version", 0, nif_version, 0},
};

ERL_NIF_INIT(wasmtime_nif, funcs, load, NULL, NULL, unload)
