/*
 * nif_values.c: Values across the boundary: value types as the NIF sees them,
 * terms to and from wasmtime_val_raw_t (numbers, v128) and wasmtime_val_t
 * (references). Never call wasm_valtype_kind: it aborts on GC types.
 */
#include "nif.h"

void vtype_of(const wasm_valtype_t *vt, vtype_t *t) {
  wasmtime_valtype_t w;
  wasmtime_valtype_new(vt, &w);
  t->kind = w.kind;
  t->fam = FAM_NUM;
  t->nullable = 1;
  if (w.kind == WASMTIME_VALTYPE_KIND_REF) {
    t->nullable = w.reftype.nullable;
    switch (w.reftype.heaptype.kind) {
    case WASMTIME_HEAPTYPE_KIND_EXTERN:
    case WASMTIME_HEAPTYPE_KIND_NOEXTERN: t->fam = FAM_EXTERN; break;
    case WASMTIME_HEAPTYPE_KIND_FUNC:
    case WASMTIME_HEAPTYPE_KIND_CONCRETE_FUNC:
    case WASMTIME_HEAPTYPE_KIND_NOFUNC: t->fam = FAM_FUNC; break;
    case WASMTIME_HEAPTYPE_KIND_EXN:
    case WASMTIME_HEAPTYPE_KIND_CONCRETE_EXN:
    case WASMTIME_HEAPTYPE_KIND_NOEXN: t->fam = FAM_EXN; break;
    default: t->fam = FAM_ANY; break;
    }
  }
  wasmtime_valtype_delete(&w);
}

uint8_t kind_of(const wasm_valtype_t *vt) {
  vtype_t t;
  vtype_of(vt, &t);
  return t.kind;
}

shape_t shape_of(const wasm_functype_t *ft) {
  shape_t sh = {0, 0, 0};
  const wasm_valtype_vec_t *vs[2] = {wasm_functype_params(ft), wasm_functype_results(ft)};
  for (int j = 0; j < 2; j++)
    for (size_t i = 0; i < vs[j]->size; i++) {
      vtype_t t;
      vtype_of(vs[j]->data[i], &t);
      if (t.kind == WASMTIME_VALTYPE_KIND_V128) sh.v128 = 1;
      if (t.kind == WASMTIME_VALTYPE_KIND_REF) sh.refs = 1;
      if (t.fam == FAM_EXN) sh.exn = 1;
    }
  return sh;
}

/* Values cross the boundary as wasmtime_val_raw_t: the typed wasmtime_val_t
 * path of the C API aborts the process on v128, the raw one supports it. The
 * kind always comes from the function type, never from the value. Reference
 * kinds never reach these two functions: they are refused when a function
 * type is inspected. */
ERL_NIF_TERM raw_to_term(ErlNifEnv *env, uint8_t kind, const wasmtime_val_raw_t *v) {
  double d;
  switch (kind) {
  case WASMTIME_VALTYPE_KIND_I32: return enif_make_int(env, v->i32);
  case WASMTIME_VALTYPE_KIND_I64: return enif_make_int64(env, v->i64);
  case WASMTIME_VALTYPE_KIND_F32: d = v->f32; goto flt;
  case WASMTIME_VALTYPE_KIND_F64: d = v->f64; goto flt;
  default: return mk_binary(env, v->v128, 16);
  }
flt:
  if (isnan(d)) return atom_nan;
  if (isinf(d)) return d > 0 ? atom_infinity : atom_neg_infinity;
  return enif_make_double(env, d);
}

static int term_to_double(ErlNifEnv *env, ERL_NIF_TERM t, double *d) {
  ErlNifSInt64 i;
  if (enif_get_double(env, t, d)) return 1;
  if (enif_get_int64(env, t, &i)) {
    *d = (double)i;
    return 1;
  }
  if (enif_is_identical(t, atom_nan)) {
    *d = NAN;
    return 1;
  }
  if (enif_is_identical(t, atom_infinity)) {
    *d = INFINITY;
    return 1;
  }
  if (enif_is_identical(t, atom_neg_infinity)) {
    *d = -INFINITY;
    return 1;
  }
  return 0;
}

int term_to_raw(ErlNifEnv *env, ERL_NIF_TERM t, uint8_t kind, wasmtime_val_raw_t *v) {
  ErlNifSInt64 i;
  ErlNifUInt64 u;
  double d;
  ErlNifBinary bin;
  memset(v, 0, sizeof *v);
  switch (kind) {
  case WASMTIME_VALTYPE_KIND_I32:
    if (!enif_get_int64(env, t, &i) || i < INT32_MIN || i > UINT32_MAX) return 0;
    v->i32 = (int32_t)(uint32_t)i;
    return 1;
  case WASMTIME_VALTYPE_KIND_I64:
    if (enif_get_int64(env, t, &i)) {
      v->i64 = i;
      return 1;
    }
    if (enif_get_uint64(env, t, &u)) {
      v->i64 = (int64_t)u;
      return 1;
    }
    return 0;
  case WASMTIME_VALTYPE_KIND_F32:
    if (!term_to_double(env, t, &d)) return 0;
    v->f32 = (float)d;
    return 1;
  case WASMTIME_VALTYPE_KIND_F64:
    if (!term_to_double(env, t, &d)) return 0;
    v->f64 = d;
    return 1;
  default:
    if (!enif_inspect_binary(env, t, &bin) || bin.size != 16) return 0;
    memcpy(v->v128, bin.data, 16);
    return 1;
  }
}

/* A wasmtime_val_t as a term, taking over its root. 0 for a kind that
 * cannot cross (exnref), unrooted. Needs exclusive use of the store. */
ERL_NIF_TERM val_to_term(ErlNifEnv *env, instance_t *inst, wasmtime_val_t *v) {
  wasmtime_val_raw_t r;
  ref_t ref;
  switch (v->kind) {
  case WASMTIME_I32: return enif_make_int(env, v->of.i32);
  case WASMTIME_I64: return enif_make_int64(env, v->of.i64);
  case WASMTIME_F32: r.f32 = v->of.f32; return raw_to_term(env, WASMTIME_VALTYPE_KIND_F32, &r);
  case WASMTIME_F64: r.f64 = v->of.f64; return raw_to_term(env, WASMTIME_VALTYPE_KIND_F64, &r);
  case WASMTIME_V128: return mk_binary(env, v->of.v128, 16);
  case WASMTIME_FUNCREF:
    if (wasmtime_funcref_is_null(&v->of.funcref)) return atom_null;
    ref.kind = REF_FUNC;
    ref.of.func = v->of.funcref;
    return mk_ref(env, inst, &ref);
#ifdef WASMTIME_FEATURE_GC
  case WASMTIME_EXTERNREF:
    if (wasmtime_externref_is_null(&v->of.externref)) return atom_null;
    ref.kind = REF_EXTERN;
    ref.of.ext = v->of.externref;
    return mk_ref(env, inst, &ref);
  case WASMTIME_ANYREF:
    if (wasmtime_anyref_is_null(&v->of.anyref)) return atom_null;
    if (wasmtime_anyref_is_i31(inst->wasm.ctx, &v->of.anyref)) {
      int32_t n = 0;
      wasmtime_anyref_i31_get_s(inst->wasm.ctx, &v->of.anyref, &n);
      wasmtime_anyref_unroot(&v->of.anyref);
      return enif_make_tuple2(env, atom_i31, enif_make_int(env, n));
    }
    ref.kind = REF_ANY;
    ref.of.any = v->of.anyref;
    return mk_ref(env, inst, &ref);
#endif
  default: wasmtime_val_unroot(v); return 0;
  }
}

/* A term as an owned wasmtime_val_t of type `t`: a fresh root for
 * references, which the caller unroots when it keeps no ownership. NULL on
 * success, else the error kind. Needs exclusive use of the store. */
const char *term_to_val(ErlNifEnv *env, instance_t *inst, ERL_NIF_TERM term, const vtype_t *t,
                        wasmtime_val_t *v) {
  memset(v, 0, sizeof *v);
  if (t->fam == FAM_NUM) {
    wasmtime_val_raw_t r;
    if (!term_to_raw(env, term, t->kind, &r)) return "badarg";
    switch (t->kind) {
    case WASMTIME_VALTYPE_KIND_I32:
      v->kind = WASMTIME_I32;
      v->of.i32 = r.i32;
      return NULL;
    case WASMTIME_VALTYPE_KIND_I64:
      v->kind = WASMTIME_I64;
      v->of.i64 = r.i64;
      return NULL;
    case WASMTIME_VALTYPE_KIND_F32:
      v->kind = WASMTIME_F32;
      v->of.f32 = r.f32;
      return NULL;
    case WASMTIME_VALTYPE_KIND_F64:
      v->kind = WASMTIME_F64;
      v->of.f64 = r.f64;
      return NULL;
    default:
      v->kind = WASMTIME_V128;
      memcpy(v->of.v128, r.v128, 16);
      return NULL;
    }
  }
  if (t->fam == FAM_EXN) return "unsupported_type";
  if (enif_is_identical(term, atom_null)) {
    if (!t->nullable) return "badarg";
    v->kind = t->fam == FAM_FUNC ? WASMTIME_FUNCREF
#ifdef WASMTIME_FEATURE_GC
              : t->fam == FAM_EXTERN ? WASMTIME_EXTERNREF
                                     : WASMTIME_ANYREF
#else
                                 : WASMTIME_FUNCREF
#endif
        ;
    return NULL; /* zeroed: store_id 0 is null for every kind */
  }
#ifdef WASMTIME_FEATURE_GC
  const ERL_NIF_TERM *tup;
  int arity;
  ErlNifSInt64 n;
  if (t->fam == FAM_ANY && enif_get_tuple(env, term, &arity, &tup) && arity == 2 &&
      enif_is_identical(tup[0], atom_i31)) {
    if (!enif_get_int64(env, tup[1], &n) || n < -(1 << 30) || n >= (1 << 30)) return "badarg";
    v->kind = WASMTIME_ANYREF;
    wasmtime_anyref_from_i31(inst->wasm.ctx, (uint32_t)n, &v->of.anyref);
    return NULL;
  }
#endif
  ref_t *r;
  if (!enif_get_resource(env, term, ref_type, (void **)&r)) return "badarg";
  if (r->inst != inst) return "wrong_instance";
  switch (t->fam) {
  case FAM_FUNC:
    if (r->kind != REF_FUNC) return "badarg";
    v->kind = WASMTIME_FUNCREF;
    v->of.funcref = r->of.func;
    return NULL;
#ifdef WASMTIME_FEATURE_GC
  case FAM_EXTERN:
    if (r->kind != REF_EXTERN) return "badarg";
    v->kind = WASMTIME_EXTERNREF;
    wasmtime_externref_clone(&r->of.ext, &v->of.externref);
    return NULL;
  default:
    if (r->kind != REF_ANY) return "badarg";
    v->kind = WASMTIME_ANYREF;
    wasmtime_anyref_clone(&r->of.any, &v->of.anyref);
    return NULL;
#else
  default: return "unavailable";
#endif
  }
}

void unroot_vals(wasmtime_val_t *vals, size_t n) {
  for (size_t i = 0; i < n; i++) wasmtime_val_unroot(&vals[i]);
}

/* The wasmtime_val_t in `v` was consumed or unrooted: report a term-side
 * conversion failure as the call error. */
ERL_NIF_TERM conv_error(ErlNifEnv *env, const char *cls, const char *kind) {
  if (strcmp(kind, "wrong_instance") == 0)
    return mk_error_s(env, cls, kind, "the reference belongs to another instance");
  if (strcmp(kind, "unsupported_type") == 0)
    return mk_error_s(env, cls, kind, "exception references cannot cross the boundary");
  if (strcmp(kind, "unavailable") == 0)
    return mk_error_s(env, cls, kind, "this build of erlang_wasmtime has no GC support");
  return mk_error_s(env, cls, kind, "value does not match the type");
}

ERL_NIF_TERM term_or_unsupported(ErlNifEnv *env, const char *cls, ERL_NIF_TERM t) {
  if (!t) return mk_error_s(env, cls, "unsupported_type", "the value cannot cross the boundary");
  return enif_make_tuple2(env, atom_ok, t);
}
