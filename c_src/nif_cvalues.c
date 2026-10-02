/*
 * nif_cvalues.c: Component values and Erlang terms, both ways, and the
 * per-instance resource table. The mapping is erlang_wasm's (wasm_canon):
 *
 *   bool             true | false
 *   s8..u64          integer, range-checked
 *   f32, f64         float, or nan | infinity | neg_infinity
 *   char             integer code point
 *   string           UTF-8 binary
 *   list<u8>         binary
 *   list<T>          list
 *   record           map, kebab-case binary keys
 *   tuple            tuple
 *   variant          {Case, Payload}, {Case, undefined} without a payload
 *   enum             binary
 *   option           none | {some, V}
 *   result           {ok, V} | {error, E}, undefined for a missing payload
 *   flags            list of binaries, in declaration order
 *   map<K, V>        map
 *   own<R>, borrow<R> integer handle into the instance's resource table
 *
 * Every string and char is checked here before it reaches the C API, which
 * unwraps UTF-8 and char conversions (a panic aborts the VM); names of
 * record fields, cases, enums and flags are taken from the type, never from
 * the term. docs/design.md, "Components".
 */
#include "nif.h"

#ifdef WASMTIME_FEATURE_COMPONENT_MODEL

static ERL_NIF_TERM atom_some_, atom_none_;

static int valid_utf8(const unsigned char *s, size_t n) {
  size_t i = 0;
  while (i < n) {
    unsigned char c = s[i];
    size_t len;
    uint32_t cp;
    if (c < 0x80) {
      i++;
      continue;
    } else if ((c & 0xE0) == 0xC0) {
      len = 2, cp = c & 0x1F;
    } else if ((c & 0xF0) == 0xE0) {
      len = 3, cp = c & 0x0F;
    } else if ((c & 0xF8) == 0xF0) {
      len = 4, cp = c & 0x07;
    } else {
      return 0;
    }
    if (i + len > n) return 0;
    for (size_t k = 1; k < len; k++) {
      if ((s[i + k] & 0xC0) != 0x80) return 0;
      cp = (cp << 6) | (s[i + k] & 0x3F);
    }
    if ((len == 2 && cp < 0x80) || (len == 3 && cp < 0x800) || (len == 4 && cp < 0x10000) ||
        cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
      return 0;
    i += len;
  }
  return 1;
}

static int valid_char(uint64_t c) {
  return c <= 0x10FFFF && !(c >= 0xD800 && c <= 0xDFFF);
}

static void set_name(wasm_name_t *dst, const char *s, size_t n) {
  wasm_name_new(dst, n, (const wasm_byte_t *)s);
}

/* A value that owns nothing, safe to delete: what unfilled slots hold. */
static void blank(wasmtime_component_val_t *v) {
  memset(v, 0, sizeof *v);
  v->kind = WASMTIME_COMPONENT_BOOL;
}

/* A heap copy of *v for the pointer fields (option, result, variant). */
static wasmtime_component_val_t *boxed(wasmtime_component_val_t *v) {
  return wasmtime_component_val_new(v);
}

/* ------------------------------------------------------- resource table */

static ERL_NIF_TERM put_resource(ErlNifEnv *env, instance_t *inst,
                                 wasmtime_component_resource_any_t *r) {
  uint32_t i;
  for (i = 0; i < inst->wasm.nres && inst->wasm.res[i]; i++) {
  }
  if (i == inst->wasm.nres) {
    if (inst->wasm.nres == inst->wasm.capres) {
      inst->wasm.capres = inst->wasm.capres ? inst->wasm.capres * 2 : 16;
      inst->wasm.res = enif_realloc(inst->wasm.res, inst->wasm.capres * sizeof *inst->wasm.res);
    }
    inst->wasm.nres++;
  }
  inst->wasm.res[i] = r;
  return enif_make_uint(env, i + 1);
}

static wasmtime_component_resource_any_t *get_resource(ErlNifEnv *env, instance_t *inst,
                                                       ERL_NIF_TERM t) {
  unsigned h;
  if (!enif_get_uint(env, t, &h) || h == 0 || h > inst->wasm.nres) return NULL;
  return inst->wasm.res[h - 1];
}

void resources_free(instance_t *inst) {
  for (uint32_t i = 0; i < inst->wasm.nres; i++)
    if (inst->wasm.res[i]) wasmtime_component_resource_any_delete(inst->wasm.res[i]);
  enif_free(inst->wasm.res);
  inst->wasm.res = NULL;
  inst->wasm.nres = inst->wasm.capres = 0;
}

/* ---------------------------------------------------- term to value */

static const char *to_int(ErlNifEnv *env, ERL_NIF_TERM t, uint8_t kind,
                          wasmtime_component_val_t *out) {
  ErlNifSInt64 i;
  ErlNifUInt64 u;
  switch (kind) {
#define SIGNED(K, V, T, LO, HI)                                                                    \
  case WASMTIME_COMPONENT_VALTYPE_##K:                                                             \
    if (!enif_get_int64(env, t, &i) || i < (LO) || i > (HI))                                       \
      return "integer out of range for " #V;                                                       \
    out->kind = WASMTIME_COMPONENT_##K;                                                            \
    out->of.V = (T)i;                                                                              \
    return NULL;
#define UNSIGNED(K, V, T, HI)                                                                      \
  case WASMTIME_COMPONENT_VALTYPE_##K:                                                             \
    if (!enif_get_uint64(env, t, &u) || u > (HI)) return "integer out of range for " #V;           \
    out->kind = WASMTIME_COMPONENT_##K;                                                            \
    out->of.V = (T)u;                                                                              \
    return NULL;
    SIGNED(S8, s8, int8_t, INT8_MIN, INT8_MAX)
    SIGNED(S16, s16, int16_t, INT16_MIN, INT16_MAX)
    SIGNED(S32, s32, int32_t, INT32_MIN, INT32_MAX)
    SIGNED(S64, s64, int64_t, INT64_MIN, INT64_MAX)
    UNSIGNED(U8, u8, uint8_t, UINT8_MAX)
    UNSIGNED(U16, u16, uint16_t, UINT16_MAX)
    UNSIGNED(U32, u32, uint32_t, UINT32_MAX)
    UNSIGNED(U64, u64, uint64_t, UINT64_MAX)
#undef SIGNED
#undef UNSIGNED
  default: return "not an integer type";
  }
}

/* Finds `name` among the names a type lists; the stored name is the type's. */
typedef int (*nth_name_fn)(const void *ty, size_t nth, const char **name, size_t *len);

static int enum_nth(const void *ty, size_t n, const char **s, size_t *l) {
  return wasmtime_component_enum_type_names_nth(ty, n, s, l);
}
static int flags_nth(const void *ty, size_t n, const char **s, size_t *l) {
  return wasmtime_component_flags_type_names_nth(ty, n, s, l);
}

static int find_name(const void *ty, size_t count, nth_name_fn nth, const ErlNifBinary *want,
                     const char **name, size_t *len) {
  for (size_t i = 0; i < count; i++)
    if (nth(ty, i, name, len) && *len == want->size && memcmp(*name, want->data, *len) == 0)
      return 1;
  return 0;
}

const char *term_to_cval(ErlNifEnv *env, instance_t *inst, ERL_NIF_TERM t,
                         const wasmtime_component_valtype_t *ty, wasmtime_component_val_t *out) {
  blank(out);
  ErlNifBinary bin;
  const ERL_NIF_TERM *tt;
  int ar;
  const char *err = NULL;
  switch (ty->kind) {
  case WASMTIME_COMPONENT_VALTYPE_BOOL:
    if (!enif_is_identical(t, atom_true) && !enif_is_identical(t, atom_false))
      return "expected true or false";
    out->of.boolean = enif_is_identical(t, atom_true);
    return NULL;
  case WASMTIME_COMPONENT_VALTYPE_S8:
  case WASMTIME_COMPONENT_VALTYPE_S16:
  case WASMTIME_COMPONENT_VALTYPE_S32:
  case WASMTIME_COMPONENT_VALTYPE_S64:
  case WASMTIME_COMPONENT_VALTYPE_U8:
  case WASMTIME_COMPONENT_VALTYPE_U16:
  case WASMTIME_COMPONENT_VALTYPE_U32:
  case WASMTIME_COMPONENT_VALTYPE_U64: return to_int(env, t, ty->kind, out);
  case WASMTIME_COMPONENT_VALTYPE_F32:
  case WASMTIME_COMPONENT_VALTYPE_F64: {
    double d;
    if (!term_to_double(env, t, &d)) return "expected a number, nan, infinity or neg_infinity";
    if (ty->kind == WASMTIME_COMPONENT_VALTYPE_F32) {
      out->kind = WASMTIME_COMPONENT_F32;
      out->of.f32 = (float)d;
    } else {
      out->kind = WASMTIME_COMPONENT_F64;
      out->of.f64 = d;
    }
    return NULL;
  }
  case WASMTIME_COMPONENT_VALTYPE_CHAR: {
    ErlNifUInt64 c;
    if (!enif_get_uint64(env, t, &c) || !valid_char(c)) return "expected a Unicode scalar value";
    out->kind = WASMTIME_COMPONENT_CHAR;
    out->of.character = (uint32_t)c;
    return NULL;
  }
  case WASMTIME_COMPONENT_VALTYPE_STRING:
    if (!enif_inspect_iolist_as_binary(env, t, &bin)) return "expected a binary";
    if (!valid_utf8(bin.data, bin.size)) return "a string must be valid UTF-8";
    out->kind = WASMTIME_COMPONENT_STRING;
    set_name(&out->of.string, (const char *)bin.data, bin.size);
    return NULL;
  case WASMTIME_COMPONENT_VALTYPE_LIST: {
    wasmtime_component_valtype_t et;
    wasmtime_component_list_type_element(ty->of.list, &et);
    out->kind = WASMTIME_COMPONENT_LIST;
    if (et.kind == WASMTIME_COMPONENT_VALTYPE_U8 && enif_inspect_binary(env, t, &bin)) {
      wasmtime_component_vallist_new_uninit(&out->of.list, bin.size);
      for (size_t i = 0; i < bin.size; i++) {
        out->of.list.data[i].kind = WASMTIME_COMPONENT_U8;
        out->of.list.data[i].of.u8 = bin.data[i];
      }
    } else {
      unsigned n;
      if (!enif_get_list_length(env, t, &n)) {
        err = "expected a list";
        wasmtime_component_vallist_new_empty(&out->of.list);
      } else {
        wasmtime_component_vallist_new_uninit(&out->of.list, n);
        for (size_t i = 0; i < n; i++) blank(&out->of.list.data[i]);
        ERL_NIF_TERM h, l = t;
        for (size_t i = 0; !err && enif_get_list_cell(env, l, &h, &l); i++)
          err = term_to_cval(env, inst, h, &et, &out->of.list.data[i]);
      }
    }
    wasmtime_component_valtype_delete(&et);
    return err;
  }
  case WASMTIME_COMPONENT_VALTYPE_RECORD: {
    const wasmtime_component_record_type_t *rt = ty->of.record;
    size_t n = wasmtime_component_record_type_field_count(rt);
    out->kind = WASMTIME_COMPONENT_RECORD;
    wasmtime_component_valrecord_new_uninit(&out->of.record, n);
    for (size_t i = 0; i < n; i++) {
      wasm_name_new_empty(&out->of.record.data[i].name);
      blank(&out->of.record.data[i].val);
    }
    if (!enif_is_map(env, t)) return "expected a map for a record";
    for (size_t i = 0; i < n && !err; i++) {
      const char *name;
      size_t len;
      wasmtime_component_valtype_t ft;
      if (!wasmtime_component_record_type_field_nth(rt, i, &name, &len, &ft))
        return "record type unreadable";
      ERL_NIF_TERM key = mk_binary(env, name, len), v;
      wasm_byte_vec_delete(&out->of.record.data[i].name);
      set_name(&out->of.record.data[i].name, name, len);
      if (!enif_get_map_value(env, t, key, &v))
        err = "a record field is missing";
      else
        err = term_to_cval(env, inst, v, &ft, &out->of.record.data[i].val);
      wasmtime_component_valtype_delete(&ft);
    }
    return err;
  }
  case WASMTIME_COMPONENT_VALTYPE_TUPLE: {
    const wasmtime_component_tuple_type_t *tp = ty->of.tuple;
    size_t n = wasmtime_component_tuple_type_types_count(tp);
    out->kind = WASMTIME_COMPONENT_TUPLE;
    wasmtime_component_valtuple_new_uninit(&out->of.tuple, n);
    for (size_t i = 0; i < n; i++) blank(&out->of.tuple.data[i]);
    if (!enif_get_tuple(env, t, &ar, &tt) || (size_t)ar != n)
      return "expected a tuple of that size";
    for (size_t i = 0; i < n && !err; i++) {
      wasmtime_component_valtype_t et;
      wasmtime_component_tuple_type_types_nth(tp, i, &et);
      err = term_to_cval(env, inst, tt[i], &et, &out->of.tuple.data[i]);
      wasmtime_component_valtype_delete(&et);
    }
    return err;
  }
  case WASMTIME_COMPONENT_VALTYPE_VARIANT: {
    /* {Case, Payload}, or Case alone for a case without payload */
    ERL_NIF_TERM name_t = t, payload = atom_undefined;
    if (enif_get_tuple(env, t, &ar, &tt) && ar == 2) name_t = tt[0], payload = tt[1];
    if (!enif_inspect_binary(env, name_t, &bin)) return "expected {Case, Payload}";
    const wasmtime_component_variant_type_t *vt = ty->of.variant;
    size_t n = wasmtime_component_variant_type_case_count(vt);
    for (size_t i = 0; i < n; i++) {
      const char *name;
      size_t len;
      bool has;
      wasmtime_component_valtype_t pt;
      if (!wasmtime_component_variant_type_case_nth(vt, i, &name, &len, &has, &pt)) continue;
      if (len != bin.size || memcmp(name, bin.data, len) != 0) {
        if (has) wasmtime_component_valtype_delete(&pt);
        continue;
      }
      out->kind = WASMTIME_COMPONENT_VARIANT;
      set_name(&out->of.variant.discriminant, name, len);
      out->of.variant.val = NULL;
      if (has) {
        wasmtime_component_val_t pv;
        err = term_to_cval(env, inst, payload, &pt, &pv);
        out->of.variant.val = boxed(&pv);
        wasmtime_component_valtype_delete(&pt);
      }
      return err;
    }
    return "no such variant case";
  }
  case WASMTIME_COMPONENT_VALTYPE_ENUM: {
    const char *name;
    size_t len;
    if (!enif_inspect_binary(env, t, &bin)) return "expected a binary enum case";
    if (!find_name(ty->of.enum_, wasmtime_component_enum_type_names_count(ty->of.enum_), enum_nth,
                   &bin, &name, &len))
      return "no such enum case";
    out->kind = WASMTIME_COMPONENT_ENUM;
    set_name(&out->of.enumeration, name, len);
    return NULL;
  }
  case WASMTIME_COMPONENT_VALTYPE_OPTION: {
    out->kind = WASMTIME_COMPONENT_OPTION;
    out->of.option = NULL;
    if (enif_is_identical(t, atom_none_)) return NULL;
    if (!enif_get_tuple(env, t, &ar, &tt) || ar != 2 || !enif_is_identical(tt[0], atom_some_))
      return "expected none or {some, Value}";
    wasmtime_component_valtype_t et;
    wasmtime_component_option_type_ty(ty->of.option, &et);
    wasmtime_component_val_t v;
    err = term_to_cval(env, inst, tt[1], &et, &v);
    out->of.option = boxed(&v);
    wasmtime_component_valtype_delete(&et);
    return err;
  }
  case WASMTIME_COMPONENT_VALTYPE_RESULT: {
    ERL_NIF_TERM tag = t, payload = atom_undefined;
    if (enif_get_tuple(env, t, &ar, &tt) && ar == 2) tag = tt[0], payload = tt[1];
    int ok = enif_is_identical(tag, atom_ok);
    if (!ok && !enif_is_identical(tag, atom_error)) return "expected {ok, Value} or {error, Value}";
    out->kind = WASMTIME_COMPONENT_RESULT;
    out->of.result.is_ok = ok;
    out->of.result.val = NULL;
    wasmtime_component_valtype_t pt;
    bool has = ok ? wasmtime_component_result_type_ok(ty->of.result, &pt)
                  : wasmtime_component_result_type_err(ty->of.result, &pt);
    if (has) {
      wasmtime_component_val_t v;
      err = term_to_cval(env, inst, payload, &pt, &v);
      out->of.result.val = boxed(&v);
      wasmtime_component_valtype_delete(&pt);
    }
    return err;
  }
  case WASMTIME_COMPONENT_VALTYPE_FLAGS: {
    const void *ft = ty->of.flags;
    size_t count = wasmtime_component_flags_type_names_count(ty->of.flags);
    unsigned n;
    out->kind = WASMTIME_COMPONENT_FLAGS;
    if (!enif_get_list_length(env, t, &n)) {
      wasmtime_component_valflags_new_empty(&out->of.flags);
      return "expected a list of flag names";
    }
    /* declaration order, each named flag once */
    wasmtime_component_valflags_new_uninit(&out->of.flags, n);
    size_t k = 0;
    for (size_t i = 0; i < n; i++) wasm_name_new_empty(&out->of.flags.data[i]);
    for (size_t f = 0; f < count && !err; f++) {
      const char *name;
      size_t len;
      if (!wasmtime_component_flags_type_names_nth(ty->of.flags, f, &name, &len)) continue;
      ERL_NIF_TERM h, l = t;
      while (enif_get_list_cell(env, l, &h, &l)) {
        if (enif_inspect_binary(env, h, &bin) && bin.size == len &&
            memcmp(bin.data, name, len) == 0) {
          wasm_byte_vec_delete(&out->of.flags.data[k]);
          set_name(&out->of.flags.data[k++], name, len);
          break;
        }
      }
    }
    /* every name given must be a flag of the type */
    ERL_NIF_TERM h, l = t;
    while (enif_get_list_cell(env, l, &h, &l)) {
      const char *name;
      size_t len;
      if (!enif_inspect_binary(env, h, &bin) || !find_name(ft, count, flags_nth, &bin, &name, &len))
        return "no such flag";
    }
    out->of.flags.size = k; /* duplicates given twice count once */
    return NULL;
  }
  case WASMTIME_COMPONENT_VALTYPE_OWN:
  case WASMTIME_COMPONENT_VALTYPE_BORROW: {
    wasmtime_component_resource_any_t *r = get_resource(env, inst, t);
    if (!r) return "not a live resource handle of this instance";
    out->kind = WASMTIME_COMPONENT_RESOURCE;
    out->of.resource = wasmtime_component_resource_any_clone(r);
    return NULL;
  }
  case WASMTIME_COMPONENT_VALTYPE_MAP: {
    wasmtime_component_valtype_t kt, vt;
    wasmtime_component_map_type_key(ty->of.map, &kt);
    wasmtime_component_map_type_value(ty->of.map, &vt);
    out->kind = WASMTIME_COMPONENT_MAP;
    size_t n;
    if (!enif_get_map_size(env, t, &n)) {
      wasmtime_component_valmap_new_empty(&out->of.map);
      err = "expected a map";
    } else {
      wasmtime_component_valmap_new_uninit(&out->of.map, n);
      for (size_t i = 0; i < n; i++)
        blank(&out->of.map.data[i].key), blank(&out->of.map.data[i].value);
      ErlNifMapIterator it;
      enif_map_iterator_create(env, t, &it, ERL_NIF_MAP_ITERATOR_FIRST);
      ERL_NIF_TERM k, v;
      for (size_t i = 0; !err && enif_map_iterator_get_pair(env, &it, &k, &v); i++) {
        err = term_to_cval(env, inst, k, &kt, &out->of.map.data[i].key);
        if (!err) err = term_to_cval(env, inst, v, &vt, &out->of.map.data[i].value);
        enif_map_iterator_next(env, &it);
      }
      enif_map_iterator_destroy(env, &it);
    }
    wasmtime_component_valtype_delete(&kt);
    wasmtime_component_valtype_delete(&vt);
    return err;
  }
  default: return "this type cannot cross yet (stream, future, error-context)";
  }
}

/* ---------------------------------------------------- value to term */

/* `ty` may be NULL when unknown (a list of u8 is then a list of integers). */
ERL_NIF_TERM cval_to_term(ErlNifEnv *env, instance_t *inst, const wasmtime_component_val_t *v,
                          const wasmtime_component_valtype_t *ty) {
  switch (v->kind) {
  case WASMTIME_COMPONENT_BOOL: return v->of.boolean ? atom_true : atom_false;
  case WASMTIME_COMPONENT_S8: return enif_make_int(env, v->of.s8);
  case WASMTIME_COMPONENT_U8: return enif_make_uint(env, v->of.u8);
  case WASMTIME_COMPONENT_S16: return enif_make_int(env, v->of.s16);
  case WASMTIME_COMPONENT_U16: return enif_make_uint(env, v->of.u16);
  case WASMTIME_COMPONENT_S32: return enif_make_int(env, v->of.s32);
  case WASMTIME_COMPONENT_U32: return enif_make_uint(env, v->of.u32);
  case WASMTIME_COMPONENT_S64: return enif_make_int64(env, v->of.s64);
  case WASMTIME_COMPONENT_U64: return enif_make_uint64(env, v->of.u64);
  case WASMTIME_COMPONENT_F32: return double_to_term(env, v->of.f32);
  case WASMTIME_COMPONENT_F64: return double_to_term(env, v->of.f64);
  case WASMTIME_COMPONENT_CHAR: return enif_make_uint(env, v->of.character);
  case WASMTIME_COMPONENT_STRING: return mk_binary(env, v->of.string.data, v->of.string.size);
  case WASMTIME_COMPONENT_LIST: {
    const wasmtime_component_vallist_t *l = &v->of.list;
    wasmtime_component_valtype_t et;
    int has_et = ty && ty->kind == WASMTIME_COMPONENT_VALTYPE_LIST;
    if (has_et) wasmtime_component_list_type_element(ty->of.list, &et);
    ERL_NIF_TERM r;
    if (has_et && et.kind == WASMTIME_COMPONENT_VALTYPE_U8) {
      unsigned char *p = enif_make_new_binary(env, l->size, &r);
      for (size_t i = 0; i < l->size; i++) p[i] = l->data[i].of.u8;
    } else {
      r = enif_make_list(env, 0);
      for (size_t i = l->size; i > 0; i--)
        r = enif_make_list_cell(env, cval_to_term(env, inst, &l->data[i - 1], has_et ? &et : NULL),
                                r);
    }
    if (has_et) wasmtime_component_valtype_delete(&et);
    return r;
  }
  case WASMTIME_COMPONENT_RECORD: {
    const wasmtime_component_valrecord_t *rec = &v->of.record;
    int typed = ty && ty->kind == WASMTIME_COMPONENT_VALTYPE_RECORD;
    ERL_NIF_TERM map = enif_make_new_map(env);
    for (size_t i = 0; i < rec->size; i++) {
      wasmtime_component_valtype_t ft;
      const char *n;
      size_t nl;
      int has_ft =
          typed && wasmtime_component_record_type_field_nth(ty->of.record, i, &n, &nl, &ft);
      ERL_NIF_TERM val = cval_to_term(env, inst, &rec->data[i].val, has_ft ? &ft : NULL);
      if (has_ft) wasmtime_component_valtype_delete(&ft);
      enif_make_map_put(env, map, mk_binary(env, rec->data[i].name.data, rec->data[i].name.size),
                        val, &map);
    }
    return map;
  }
  case WASMTIME_COMPONENT_TUPLE: {
    const wasmtime_component_valtuple_t *tp = &v->of.tuple;
    int typed = ty && ty->kind == WASMTIME_COMPONENT_VALTYPE_TUPLE;
    ERL_NIF_TERM *items = enif_alloc((tp->size ? tp->size : 1) * sizeof *items);
    for (size_t i = 0; i < tp->size; i++) {
      wasmtime_component_valtype_t et;
      int has = typed && wasmtime_component_tuple_type_types_nth(ty->of.tuple, i, &et);
      items[i] = cval_to_term(env, inst, &tp->data[i], has ? &et : NULL);
      if (has) wasmtime_component_valtype_delete(&et);
    }
    ERL_NIF_TERM r = enif_make_tuple_from_array(env, items, (unsigned)tp->size);
    enif_free(items);
    return r;
  }
  case WASMTIME_COMPONENT_VARIANT: {
    const wasmtime_component_valvariant_t *vr = &v->of.variant;
    ERL_NIF_TERM name = mk_binary(env, vr->discriminant.data, vr->discriminant.size);
    ERL_NIF_TERM payload = atom_undefined;
    if (vr->val) {
      wasmtime_component_valtype_t pt;
      int has = 0;
      if (ty && ty->kind == WASMTIME_COMPONENT_VALTYPE_VARIANT) {
        size_t n = wasmtime_component_variant_type_case_count(ty->of.variant);
        for (size_t i = 0; i < n && !has; i++) {
          const char *cn;
          size_t cl;
          bool hp;
          if (!wasmtime_component_variant_type_case_nth(ty->of.variant, i, &cn, &cl, &hp, &pt))
            continue;
          if (cl == vr->discriminant.size && memcmp(cn, vr->discriminant.data, cl) == 0 && hp)
            has = 1;
          else if (hp)
            wasmtime_component_valtype_delete(&pt);
        }
      }
      payload = cval_to_term(env, inst, vr->val, has ? &pt : NULL);
      if (has) wasmtime_component_valtype_delete(&pt);
    }
    return enif_make_tuple2(env, name, payload);
  }
  case WASMTIME_COMPONENT_ENUM:
    return mk_binary(env, v->of.enumeration.data, v->of.enumeration.size);
  case WASMTIME_COMPONENT_OPTION: {
    if (!v->of.option) return atom_none_;
    wasmtime_component_valtype_t et;
    int has = ty && ty->kind == WASMTIME_COMPONENT_VALTYPE_OPTION;
    if (has) wasmtime_component_option_type_ty(ty->of.option, &et);
    ERL_NIF_TERM r =
        enif_make_tuple2(env, atom_some_, cval_to_term(env, inst, v->of.option, has ? &et : NULL));
    if (has) wasmtime_component_valtype_delete(&et);
    return r;
  }
  case WASMTIME_COMPONENT_RESULT: {
    const wasmtime_component_valresult_t *rs = &v->of.result;
    ERL_NIF_TERM payload = atom_undefined;
    if (rs->val) {
      wasmtime_component_valtype_t pt;
      int has = ty && ty->kind == WASMTIME_COMPONENT_VALTYPE_RESULT &&
                (rs->is_ok ? wasmtime_component_result_type_ok(ty->of.result, &pt)
                           : wasmtime_component_result_type_err(ty->of.result, &pt));
      payload = cval_to_term(env, inst, rs->val, has ? &pt : NULL);
      if (has) wasmtime_component_valtype_delete(&pt);
    }
    return enif_make_tuple2(env, rs->is_ok ? atom_ok : atom_error, payload);
  }
  case WASMTIME_COMPONENT_FLAGS: {
    ERL_NIF_TERM r = enif_make_list(env, 0);
    for (size_t i = v->of.flags.size; i > 0; i--)
      r = enif_make_list_cell(
          env, mk_binary(env, v->of.flags.data[i - 1].data, v->of.flags.data[i - 1].size), r);
    return r;
  }
  case WASMTIME_COMPONENT_MAP: {
    wasmtime_component_valtype_t kt, vt;
    int has = ty && ty->kind == WASMTIME_COMPONENT_VALTYPE_MAP;
    if (has) {
      wasmtime_component_map_type_key(ty->of.map, &kt);
      wasmtime_component_map_type_value(ty->of.map, &vt);
    }
    ERL_NIF_TERM map = enif_make_new_map(env);
    for (size_t i = 0; i < v->of.map.size; i++)
      enif_make_map_put(env, map, cval_to_term(env, inst, &v->of.map.data[i].key, has ? &kt : NULL),
                        cval_to_term(env, inst, &v->of.map.data[i].value, has ? &vt : NULL), &map);
    if (has) {
      wasmtime_component_valtype_delete(&kt);
      wasmtime_component_valtype_delete(&vt);
    }
    return map;
  }
  case WASMTIME_COMPONENT_RESOURCE:
    return put_resource(env, inst, wasmtime_component_resource_any_clone(v->of.resource));
  default: return atom_undefined;
  }
}

/* Called at load. */
void cvalues_init(ErlNifEnv *env) {
  atom_some_ = mk_atom(env, "some");
  atom_none_ = mk_atom(env, "none");
}

#else
void cvalues_init(ErlNifEnv *env) {
  (void)env;
}
#endif

/* A component binary: the preamble's layer field is 1 (a core module's is 0). */
int is_component_binary(const uint8_t *data, size_t size) {
  return size >= 8 && memcmp(data, "\0asm", 4) == 0 && data[6] == 1 && data[7] == 0;
}
