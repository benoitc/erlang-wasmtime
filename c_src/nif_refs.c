/*
 * nif_refs.c: References as terms: the ref_t resource (an owned GC root or a
 * funcref), externref payloads, struct and array access, gc/1.
 */
#include "nif.h"

void ref_dtor(ErlNifEnv *env, void *obj) {
  ref_t *r = obj;
#ifdef WASMTIME_FEATURE_GC
  if (r->kind == REF_EXTERN) wasmtime_externref_unroot(&r->of.ext);
  if (r->kind == REF_ANY) wasmtime_anyref_unroot(&r->of.any);
#endif
  enif_release_resource(r->inst);
}

/* Wraps `src` (whose root, if any, the resource takes over). */
ERL_NIF_TERM mk_ref(ErlNifEnv *env, instance_t *inst, const ref_t *src) {
  ref_t *r = enif_alloc_resource(ref_type, sizeof *r);
  *r = *src;
  r->inst = inst;
  enif_keep_resource(inst);
  ERL_NIF_TERM t = enif_make_resource(env, r);
  enif_release_resource(r);
  return t;
}

/* ref_info(Ref) -> #{kind => externref | funcref | struct | array | anyref, instance => Ref} */
ERL_NIF_TERM nif_ref_info(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ref_t *r;
  ERL_NIF_TERM err = with_ref(env, argv[0], &r);
  if (err) return err;
  ERL_NIF_TERM kind = atom_funcref;
#ifdef WASMTIME_FEATURE_GC
  if (r->kind == REF_EXTERN) kind = atom_externref;
  if (r->kind == REF_ANY)
    kind = wasmtime_anyref_is_struct(r->inst->wasm.ctx, &r->of.any)  ? atom_struct
           : wasmtime_anyref_is_array(r->inst->wasm.ctx, &r->of.any) ? atom_array
                                                                     : atom_anyref;
#endif
  ERL_NIF_TERM keys[2] = {atom_kind, atom_instance};
  ERL_NIF_TERM vals[2] = {kind, enif_make_copy(env, r->inst->ref)};
  ERL_NIF_TERM map;
  enif_make_map_from_arrays(env, keys, vals, 2, &map);
  pthread_mutex_unlock(&r->inst->mu);
  return map;
}

#ifdef WASMTIME_FEATURE_GC
/* What an externref made by externref/2 carries: a term in its own env. */
typedef struct {
  ErlNifEnv *env;
  ERL_NIF_TERM term;
} payload_t;

/* Wasmtime's collector runs this on any thread, without the store. */
static void payload_free(void *p) {
  payload_t *pl = p;
  enif_free_env(pl->env);
  enif_free(pl);
}

/* externref(Handle, Term) -> {ok, Ref}: the term lives in an env the
 * object owns until Wasmtime's collector drops it. */
ERL_NIF_TERM nif_externref(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst)) return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r;
  if (inst->queue.state == ST_RUNNING) {
    r = mk_error_s(env, "ref", "busy", "guest is running");
  } else if (!inst->wasm.instantiated) {
    r = mk_error_s(env, "ref", "stopped", "instance is stopped");
  } else {
    payload_t *pl = enif_alloc(sizeof *pl);
    pl->env = enif_alloc_env();
    pl->term = enif_make_copy(pl->env, argv[1]);
    ref_t ref = {.kind = REF_EXTERN};
    if (!wasmtime_externref_new(inst->wasm.ctx, pl, payload_free, &ref.of.ext)) {
      payload_free(pl);
      r = mk_error_s(env, "ref", "gc_heap_full", "no room for another GC object: try gc/1");
    } else {
      r = enif_make_tuple2(env, atom_ok, mk_ref(env, inst, &ref));
    }
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

/* externref_data(Ref) -> {ok, Term} */
ERL_NIF_TERM nif_externref_data(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ref_t *r;
  ERL_NIF_TERM err = with_ref(env, argv[0], &r);
  if (err) return err;
  ERL_NIF_TERM res;
  payload_t *pl =
      r->kind == REF_EXTERN ? wasmtime_externref_data(r->inst->wasm.ctx, &r->of.ext) : NULL;
  if (!pl)
    res = mk_error_s(env, "ref", "badarg", "not an externref made by externref/2");
  else
    res = enif_make_tuple2(env, atom_ok, enif_make_copy(env, pl->term));
  pthread_mutex_unlock(&r->inst->mu);
  return res;
}

/* The struct or array behind an anyref, as a fresh root the caller unroots. */
static int as_struct(ref_t *r, wasmtime_structref_t *out) {
  return r->kind == REF_ANY && wasmtime_anyref_as_struct(r->inst->wasm.ctx, &r->of.any, out);
}

static int as_array(ref_t *r, wasmtime_arrayref_t *out) {
  return r->kind == REF_ANY && wasmtime_anyref_as_array(r->inst->wasm.ctx, &r->of.any, out);
}

/* A field's storage type as the boundary sees it: i8 and i16 cross as i32. */
static void field_vtype(const wasmtime_field_type_t *ft, vtype_t *t) {
  if (ft->storage.kind == WASMTIME_STORAGE_TYPE_KIND_VALTYPE) {
    vtype_of(ft->storage.valtype, t);
  } else {
    t->kind = WASMTIME_VALTYPE_KIND_I32;
    t->fam = FAM_NUM;
    t->nullable = 1;
  }
}

/* struct_get(Ref, Index) -> {ok, Value} */
ERL_NIF_TERM nif_struct_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 index;
  if (!enif_get_uint64(env, argv[1], &index)) return enif_make_badarg(env);
  ref_t *r;
  ERL_NIF_TERM err = with_ref(env, argv[0], &r);
  if (err) return err;
  ERL_NIF_TERM res;
  wasmtime_structref_t st;
  if (!as_struct(r, &st)) {
    res = mk_error_s(env, "ref", "badarg", "not a struct");
  } else {
    wasmtime_val_t v;
    wasmtime_error_t *e = wasmtime_structref_field(r->inst->wasm.ctx, &st, index, &v);
    res = e ? error_to_term(env, e, "ref")
            : term_or_unsupported(env, "ref", val_to_term(env, r->inst, &v));
    wasmtime_structref_unroot(&st);
  }
  pthread_mutex_unlock(&r->inst->mu);
  return res;
}

/* struct_set(Ref, Index, Value) -> ok */
ERL_NIF_TERM nif_struct_set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 index;
  if (!enif_get_uint64(env, argv[1], &index)) return enif_make_badarg(env);
  ref_t *r;
  ERL_NIF_TERM err = with_ref(env, argv[0], &r);
  if (err) return err;
  ERL_NIF_TERM res;
  wasmtime_structref_t st;
  wasmtime_field_type_t ft;
  if (!as_struct(r, &st)) {
    res = mk_error_s(env, "ref", "badarg", "not a struct");
  } else {
    wasmtime_struct_type_t *ty = wasmtime_structref_type(r->inst->wasm.ctx, &st);
    if (!wasmtime_struct_type_field(ty, index, &ft)) {
      res = mk_error_s(env, "ref", "out_of_bounds", "no such field");
    } else {
      vtype_t t;
      field_vtype(&ft, &t);
      wasmtime_val_t v;
      const char *kind = term_to_val(env, r->inst, argv[2], &t, &v);
      if (kind) {
        res = conv_error(env, "ref", kind);
      } else {
        wasmtime_error_t *e = wasmtime_structref_set_field(r->inst->wasm.ctx, &st, index, &v);
        wasmtime_val_unroot(&v);
        res = e ? error_to_term(env, e, "ref") : atom_ok;
      }
      wasmtime_field_type_delete(&ft);
    }
    wasmtime_struct_type_delete(ty);
    wasmtime_structref_unroot(&st);
  }
  pthread_mutex_unlock(&r->inst->mu);
  return res;
}

/* array_len(Ref) -> {ok, N} */
ERL_NIF_TERM nif_array_len(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ref_t *r;
  ERL_NIF_TERM err = with_ref(env, argv[0], &r);
  if (err) return err;
  ERL_NIF_TERM res;
  wasmtime_arrayref_t ar;
  if (!as_array(r, &ar)) {
    res = mk_error_s(env, "ref", "badarg", "not an array");
  } else {
    uint32_t n = 0;
    wasmtime_error_t *e = wasmtime_arrayref_len(r->inst->wasm.ctx, &ar, &n);
    res = e ? error_to_term(env, e, "ref") : enif_make_tuple2(env, atom_ok, enif_make_uint(env, n));
    wasmtime_arrayref_unroot(&ar);
  }
  pthread_mutex_unlock(&r->inst->mu);
  return res;
}

/* array_get(Ref, Index) -> {ok, Value} */
ERL_NIF_TERM nif_array_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 index;
  if (!enif_get_uint64(env, argv[1], &index)) return enif_make_badarg(env);
  ref_t *r;
  ERL_NIF_TERM err = with_ref(env, argv[0], &r);
  if (err) return err;
  ERL_NIF_TERM res;
  wasmtime_arrayref_t ar;
  if (!as_array(r, &ar)) {
    res = mk_error_s(env, "ref", "badarg", "not an array");
  } else if (index > UINT32_MAX) {
    res = mk_error_s(env, "ref", "out_of_bounds", "index is past the array's length");
    wasmtime_arrayref_unroot(&ar);
  } else {
    wasmtime_val_t v;
    wasmtime_error_t *e = wasmtime_arrayref_get(r->inst->wasm.ctx, &ar, (uint32_t)index, &v);
    res = e ? error_to_term(env, e, "ref")
            : term_or_unsupported(env, "ref", val_to_term(env, r->inst, &v));
    wasmtime_arrayref_unroot(&ar);
  }
  pthread_mutex_unlock(&r->inst->mu);
  return res;
}

/* array_set(Ref, Index, Value) -> ok */
ERL_NIF_TERM nif_array_set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ErlNifUInt64 index;
  if (!enif_get_uint64(env, argv[1], &index)) return enif_make_badarg(env);
  ref_t *r;
  ERL_NIF_TERM err = with_ref(env, argv[0], &r);
  if (err) return err;
  ERL_NIF_TERM res;
  wasmtime_arrayref_t ar;
  if (!as_array(r, &ar)) {
    res = mk_error_s(env, "ref", "badarg", "not an array");
  } else if (index > UINT32_MAX) {
    res = mk_error_s(env, "ref", "out_of_bounds", "index is past the array's length");
    wasmtime_arrayref_unroot(&ar);
  } else {
    wasmtime_array_type_t *ty = wasmtime_arrayref_type(r->inst->wasm.ctx, &ar);
    wasmtime_field_type_t ft;
    wasmtime_array_type_element(ty, &ft);
    vtype_t t;
    field_vtype(&ft, &t);
    wasmtime_val_t v;
    const char *kind = term_to_val(env, r->inst, argv[2], &t, &v);
    if (kind) {
      res = conv_error(env, "ref", kind);
    } else {
      wasmtime_error_t *e = wasmtime_arrayref_set(r->inst->wasm.ctx, &ar, (uint32_t)index, &v);
      wasmtime_val_unroot(&v);
      res = e ? error_to_term(env, e, "ref") : atom_ok;
    }
    wasmtime_field_type_delete(&ft);
    wasmtime_array_type_delete(ty);
    wasmtime_arrayref_unroot(&ar);
  }
  pthread_mutex_unlock(&r->inst->mu);
  return res;
}

/* gc(Handle) -> ok */
ERL_NIF_TERM nif_gc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  instance_t *inst;
  if (!get_handle(env, argv[0], &inst)) return enif_make_badarg(env);
  pthread_mutex_lock(&inst->mu);
  ERL_NIF_TERM r;
  if (inst->queue.state == ST_RUNNING) {
    r = mk_error_s(env, "ref", "busy", "guest is running");
  } else if (!inst->wasm.instantiated) {
    r = mk_error_s(env, "ref", "stopped", "instance is stopped");
  } else {
    wasmtime_error_t *e = wasmtime_context_gc(inst->wasm.ctx);
    r = e ? error_to_term(env, e, "ref") : atom_ok;
  }
  pthread_mutex_unlock(&inst->mu);
  return r;
}

#else
static ERL_NIF_TERM nif_no_gc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  return mk_error_s(env, "ref", "unavailable", "this build of erlang_wasmtime has no GC support");
}
#endif
